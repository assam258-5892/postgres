/*-------------------------------------------------------------------------
 *
 * nodeWindowAgg.c
 *	  routines to handle WindowAgg nodes.
 *
 * A WindowAgg node evaluates "window functions" across suitable partitions
 * of the input tuple set.  Any one WindowAgg works for just a single window
 * specification, though it can evaluate multiple window functions sharing
 * identical window specifications.  The input tuples are required to be
 * delivered in sorted order, with the PARTITION BY columns (if any) as
 * major sort keys and the ORDER BY columns (if any) as minor sort keys.
 * (The planner generates a stack of WindowAggs with intervening Sort nodes
 * as needed, if a query involves more than one window specification.)
 *
 * Since window functions can require access to any or all of the rows in
 * the current partition, we accumulate rows of the partition into a
 * tuplestore.  The window functions are called using the WindowObject API
 * so that they can access those rows as needed.
 *
 * We also support using plain aggregate functions as window functions.
 * For these, the regular Agg-node environment is emulated for each partition.
 * As required by the SQL spec, the output represents the value of the
 * aggregate function over all rows in the current row's window frame.
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  src/backend/executor/nodeWindowAgg.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_aggregate.h"
#include "catalog/pg_proc.h"
#include "common/int.h"
#include "executor/executor.h"
#include "executor/execRPR.h"
#include "executor/instrument.h"
#include "executor/nodeWindowAgg.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "nodes/plannodes.h"
#include "optimizer/clauses.h"
#include "optimizer/optimizer.h"
#include "parser/parse_agg.h"
#include "parser/parse_coerce.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/expandeddatum.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/regproc.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"
#include "windowapi.h"

/*
 * All the window function APIs are called with this object, which is passed
 * to window functions as fcinfo->context.
 */
typedef struct WindowObjectData
{
	NodeTag		type;
	WindowAggState *winstate;	/* parent WindowAggState */
	List	   *argstates;		/* ExprState trees for fn's arguments */
	void	   *localmem;		/* WinGetPartitionLocalMemory's chunk */
	int			markptr;		/* tuplestore mark pointer for this fn */
	int			readptr;		/* tuplestore read pointer for this fn */
	int64		markpos;		/* row that markptr is positioned on */
	int64		seekpos;		/* row that readptr is positioned on */
	uint8	  **notnull_info;	/* not null info for each func args */
	int64	   *num_notnull_info;	/* track size (number of tuples in
									 * partition) of the notnull_info array
									 * for each func args */
	bool	   *notnull_info_cacheable; /* can we cache notnull_info? */

	/*
	 * Null treatment options. One of: NO_NULLTREATMENT, PARSER_IGNORE_NULLS,
	 * PARSER_RESPECT_NULLS or IGNORE_NULLS.
	 */
	int			ignore_nulls;
} WindowObjectData;

/*
 * We have one WindowStatePerFunc struct for each window function and
 * window aggregate handled by this node.
 */
typedef struct WindowStatePerFuncData
{
	/* Links to WindowFunc expr and state nodes this working state is for */
	WindowFuncExprState *wfuncstate;
	WindowFunc *wfunc;

	int			numArguments;	/* number of arguments */

	FmgrInfo	flinfo;			/* fmgr lookup data for window function */

	Oid			winCollation;	/* collation derived for window function */

	/*
	 * We need the len and byval info for the result of each function in order
	 * to know how to copy/delete values.
	 */
	int16		resulttypeLen;
	bool		resulttypeByVal;

	bool		plain_agg;		/* is it just a plain aggregate function? */
	int			aggno;			/* if so, index of its WindowStatePerAggData */

	WindowObject winobj;		/* object used in window function API */
} WindowStatePerFuncData;

/*
 * For plain aggregate window functions, we also have one of these.
 */
typedef struct WindowStatePerAggData
{
	/* Oids of transition functions */
	Oid			transfn_oid;
	Oid			invtransfn_oid; /* may be InvalidOid */
	Oid			finalfn_oid;	/* may be InvalidOid */

	/*
	 * fmgr lookup data for transition functions --- only valid when
	 * corresponding oid is not InvalidOid.  Note in particular that fn_strict
	 * flags are kept here.
	 */
	FmgrInfo	transfn;
	FmgrInfo	invtransfn;
	FmgrInfo	finalfn;

	int			numFinalArgs;	/* number of arguments to pass to finalfn */

	/*
	 * initial value from pg_aggregate entry
	 */
	Datum		initValue;
	bool		initValueIsNull;

	/*
	 * cached value for current frame boundaries
	 */
	Datum		resultValue;
	bool		resultValueIsNull;

	/*
	 * We need the len and byval info for the agg's input, result, and
	 * transition data types in order to know how to copy/delete values.
	 */
	int16		inputtypeLen,
				resulttypeLen,
				transtypeLen;
	bool		inputtypeByVal,
				resulttypeByVal,
				transtypeByVal;

	int			wfuncno;		/* index of associated WindowStatePerFuncData */

	/* Context holding transition value and possibly other subsidiary data */
	MemoryContext aggcontext;	/* may be private, or winstate->aggcontext */

	/* Current transition value */
	Datum		transValue;		/* current transition value */
	bool		transValueIsNull;

	int64		transValueCount;	/* number of currently-aggregated rows */

	/* Data local to eval_windowaggregates() */
	bool		restart;		/* need to restart this agg in this cycle? */
} WindowStatePerAggData;

typedef struct
{
	WindowAggState *winstate;
	int64		maxOffset;		/* 모든 nav 표현식에 걸친 최대 후방 도달
								 * 오프셋 */
	bool		maxOverflow;	/* 후방 도달 오버플로가 감지되면 true */
	int64		minFirstOffset; /* match_start 로부터의 최소 전방 오프셋.
								 * 음수일 수 있음(PREV_FIRST: inner - outer
								 * < 0) */
	bool		hasMax;			/* 후방 도달 nav가 하나라도 있으면 true */
	bool		hasFirst;		/* FIRST 기반 nav가 하나라도 있으면 true */
	bool		validate;		/* null/음수 오프셋에서 fail-closed할지
								 * 여부? 초기화 시(표시 전용)에는 false, 실행
								 * 시에는 true */
} EvalDefineOffsetsContext;

static void initialize_windowaggregate(WindowAggState *winstate,
									   WindowStatePerFunc perfuncstate,
									   WindowStatePerAgg peraggstate);
static void advance_windowaggregate(WindowAggState *winstate,
									WindowStatePerFunc perfuncstate,
									WindowStatePerAgg peraggstate);
static bool advance_windowaggregate_base(WindowAggState *winstate,
										 WindowStatePerFunc perfuncstate,
										 WindowStatePerAgg peraggstate);
static void finalize_windowaggregate(WindowAggState *winstate,
									 WindowStatePerFunc perfuncstate,
									 WindowStatePerAgg peraggstate,
									 Datum *result, bool *isnull);

static void eval_windowaggregates(WindowAggState *winstate);
static void eval_windowfunction(WindowAggState *winstate,
								WindowStatePerFunc perfuncstate,
								Datum *result, bool *isnull);

static void begin_partition(WindowAggState *winstate);
static void spool_tuples(WindowAggState *winstate, int64 pos);
static void release_partition(WindowAggState *winstate);

static int	row_is_in_frame(WindowObject winobj, int64 pos,
							TupleTableSlot *slot, bool fetch_tuple);
static void update_frameheadpos(WindowAggState *winstate);
static void update_frametailpos(WindowAggState *winstate);
static void update_grouptailpos(WindowAggState *winstate);

static WindowStatePerAggData *initialize_peragg(WindowAggState *winstate,
												WindowFunc *wfunc,
												WindowStatePerAgg peraggstate);
static Datum GetAggInitVal(Datum textInitVal, Oid transtype);

static bool are_peers(WindowAggState *winstate, TupleTableSlot *slot1,
					  TupleTableSlot *slot2);
static int	WinGetSlotInFrame(WindowObject winobj, TupleTableSlot *slot,
							  int relpos, int seektype, bool set_mark,
							  bool *isnull, bool *isout);
static bool window_gettupleslot(WindowObject winobj, int64 pos,
								TupleTableSlot *slot);

static Datum ignorenulls_getfuncarginframe(WindowObject winobj, int argno,
										   int relpos, int seektype,
										   bool set_mark, bool *isnull,
										   bool *isout);
static Datum gettuple_eval_partition(WindowObject winobj, int argno,
									 int64 abs_pos, bool *isnull,
									 bool *isout);
static void init_notnull_info(WindowObject winobj,
							  WindowStatePerFunc perfuncstate);
static void grow_notnull_info(WindowObject winobj,
							  int64 pos, int argno);
static uint8 get_notnull_info(WindowObject winobj,
							  int64 pos, int argno);
static void put_notnull_info(WindowObject winobj,
							 int64 pos, int argno, bool isnull);
static bool rpr_is_defined(WindowAggState *winstate);
static int64 row_is_in_reduced_frame(WindowObject winobj, int64 pos);
static void ensure_reduced_frame(WindowObject winobj, int64 pos);

static void clear_reduced_frame(WindowAggState *winstate);
static int	get_reduced_frame_status(WindowAggState *winstate, int64 pos);
static void advance_nav_mark(WindowAggState *winstate, int64 currentPos);
static void advance_reduced_frame_nfa(WindowObject winobj,
									  RPRNFAContext *targetCtx);
static void update_reduced_frame(WindowObject winobj, int64 pos);

/* 전방 선언 - DEFINE 행 평가 */
static bool rpr_prepare_row(WindowObject winobj, int64 pos, RPRVarMatch *varMatched);
static void build_define_offsets(WindowAggState *winstate, List *defineClause);
static void resolve_nav_offsets(WindowAggState *winstate);
static void resolve_one_nav(RPRNavOffsets *entry, EvalDefineOffsetsContext *context);
static bool nav_offsets_walker(Node *node, WindowAggState *winstate);
static void build_nav_offsets(RPRNavExpr *nav, WindowAggState *winstate);

/*
 * Not null info bit array consists of 2-bit items
 */
#define	NN_UNKNOWN	0x00		/* value not calculated yet */
#define	NN_NULL		0x01		/* NULL */
#define	NN_NOTNULL	0x02		/* NOT NULL */
#define	NN_MASK		0x03		/* mask for NOT NULL MAP */
#define NN_BITS_PER_MEMBER	2	/* number of bits in not null map */
/* number of items per variable */
#define NN_ITEM_PER_VAR	(BITS_PER_BYTE / NN_BITS_PER_MEMBER)
/* convert map position to byte offset */
#define NN_POS_TO_BYTES(pos)	((pos) / NN_ITEM_PER_VAR)
/* bytes offset to map position */
#define NN_BYTES_TO_POS(bytes)	((bytes) * NN_ITEM_PER_VAR)
/* calculate shift bits */
#define	NN_SHIFT(pos)	((pos) % NN_ITEM_PER_VAR) * NN_BITS_PER_MEMBER

/*
 * initialize_windowaggregate
 * parallel to initialize_aggregates in nodeAgg.c
 */
static void
initialize_windowaggregate(WindowAggState *winstate,
						   WindowStatePerFunc perfuncstate,
						   WindowStatePerAgg peraggstate)
{
	MemoryContext oldContext;

	/*
	 * If we're using a private aggcontext, we may reset it here.  But if the
	 * context is shared, we don't know which other aggregates may still need
	 * it, so we must leave it to the caller to reset at an appropriate time.
	 */
	if (peraggstate->aggcontext != winstate->aggcontext)
		MemoryContextReset(peraggstate->aggcontext);

	if (peraggstate->initValueIsNull)
		peraggstate->transValue = peraggstate->initValue;
	else
	{
		oldContext = MemoryContextSwitchTo(peraggstate->aggcontext);
		peraggstate->transValue = datumCopy(peraggstate->initValue,
											peraggstate->transtypeByVal,
											peraggstate->transtypeLen);
		MemoryContextSwitchTo(oldContext);
	}
	peraggstate->transValueIsNull = peraggstate->initValueIsNull;
	peraggstate->transValueCount = 0;
	peraggstate->resultValue = (Datum) 0;
	peraggstate->resultValueIsNull = true;
}

/*
 * advance_windowaggregate
 * parallel to advance_aggregates in nodeAgg.c
 */
static void
advance_windowaggregate(WindowAggState *winstate,
						WindowStatePerFunc perfuncstate,
						WindowStatePerAgg peraggstate)
{
	LOCAL_FCINFO(fcinfo, FUNC_MAX_ARGS);
	WindowFuncExprState *wfuncstate = perfuncstate->wfuncstate;
	int			numArguments = perfuncstate->numArguments;
	Datum		newVal;
	ListCell   *arg;
	int			i;
	MemoryContext oldContext;
	ExprContext *econtext = winstate->tmpcontext;
	ExprState  *filter = wfuncstate->aggfilter;

	oldContext = MemoryContextSwitchTo(econtext->ecxt_per_tuple_memory);

	/* Skip anything FILTERed out */
	if (filter)
	{
		bool		isnull;
		Datum		res = ExecEvalExpr(filter, econtext, &isnull);

		if (isnull || !DatumGetBool(res))
		{
			MemoryContextSwitchTo(oldContext);
			return;
		}
	}

	/* We start from 1, since the 0th arg will be the transition value */
	i = 1;
	foreach(arg, wfuncstate->args)
	{
		ExprState  *argstate = (ExprState *) lfirst(arg);

		fcinfo->args[i].value = ExecEvalExpr(argstate, econtext,
											 &fcinfo->args[i].isnull);
		i++;
	}

	if (peraggstate->transfn.fn_strict)
	{
		/*
		 * For a strict transfn, nothing happens when there's a NULL input; we
		 * just keep the prior transValue.  Note transValueCount doesn't
		 * change either.
		 */
		for (i = 1; i <= numArguments; i++)
		{
			if (fcinfo->args[i].isnull)
			{
				MemoryContextSwitchTo(oldContext);
				return;
			}
		}

		/*
		 * For strict transition functions with initial value NULL we use the
		 * first non-NULL input as the initial state.  (We already checked
		 * that the agg's input type is binary-compatible with its transtype,
		 * so straight copy here is OK.)
		 *
		 * We must copy the datum into aggcontext if it is pass-by-ref.  We do
		 * not need to pfree the old transValue, since it's NULL.
		 */
		if (peraggstate->transValueCount == 0 && peraggstate->transValueIsNull)
		{
			MemoryContextSwitchTo(peraggstate->aggcontext);
			peraggstate->transValue = datumCopy(fcinfo->args[1].value,
												peraggstate->transtypeByVal,
												peraggstate->transtypeLen);
			peraggstate->transValueIsNull = false;
			peraggstate->transValueCount = 1;
			MemoryContextSwitchTo(oldContext);
			return;
		}

		if (peraggstate->transValueIsNull)
		{
			/*
			 * Don't call a strict function with NULL inputs.  Note it is
			 * possible to get here despite the above tests, if the transfn is
			 * strict *and* returned a NULL on a prior cycle.  If that happens
			 * we will propagate the NULL all the way to the end.  That can
			 * only happen if there's no inverse transition function, though,
			 * since we disallow transitions back to NULL when there is one.
			 */
			MemoryContextSwitchTo(oldContext);
			Assert(!OidIsValid(peraggstate->invtransfn_oid));
			return;
		}
	}

	/*
	 * OK to call the transition function.  Set winstate->curaggcontext while
	 * calling it, for possible use by AggCheckCallContext.
	 */
	InitFunctionCallInfoData(*fcinfo, &(peraggstate->transfn),
							 numArguments + 1,
							 perfuncstate->winCollation,
							 (Node *) winstate, NULL);
	fcinfo->args[0].value = peraggstate->transValue;
	fcinfo->args[0].isnull = peraggstate->transValueIsNull;
	winstate->curaggcontext = peraggstate->aggcontext;
	newVal = FunctionCallInvoke(fcinfo);
	winstate->curaggcontext = NULL;

	/*
	 * Moving-aggregate transition functions must not return null, see
	 * advance_windowaggregate_base().
	 */
	if (fcinfo->isnull && OidIsValid(peraggstate->invtransfn_oid))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("moving-aggregate transition function must not return null")));

	/*
	 * We must track the number of rows included in transValue, since to
	 * remove the last input, advance_windowaggregate_base() mustn't call the
	 * inverse transition function, but simply reset transValue back to its
	 * initial value.
	 */
	peraggstate->transValueCount++;

	/*
	 * If pass-by-ref datatype, must copy the new value into aggcontext and
	 * free the prior transValue.  But if transfn returned a pointer to its
	 * first input, we don't need to do anything.  Also, if transfn returned a
	 * pointer to a R/W expanded object that is already a child of the
	 * aggcontext, assume we can adopt that value without copying it.  (See
	 * comments for ExecAggCopyTransValue, which this code duplicates.)
	 */
	if (!peraggstate->transtypeByVal &&
		DatumGetPointer(newVal) != DatumGetPointer(peraggstate->transValue))
	{
		if (!fcinfo->isnull)
		{
			MemoryContextSwitchTo(peraggstate->aggcontext);
			if (DatumIsReadWriteExpandedObject(newVal,
											   false,
											   peraggstate->transtypeLen) &&
				MemoryContextGetParent(DatumGetEOHP(newVal)->eoh_context) == CurrentMemoryContext)
				 /* do nothing */ ;
			else
				newVal = datumCopy(newVal,
								   peraggstate->transtypeByVal,
								   peraggstate->transtypeLen);
		}
		if (!peraggstate->transValueIsNull)
		{
			if (DatumIsReadWriteExpandedObject(peraggstate->transValue,
											   false,
											   peraggstate->transtypeLen))
				DeleteExpandedObject(peraggstate->transValue);
			else
				pfree(DatumGetPointer(peraggstate->transValue));
		}
	}

	MemoryContextSwitchTo(oldContext);
	peraggstate->transValue = newVal;
	peraggstate->transValueIsNull = fcinfo->isnull;
}

/*
 * advance_windowaggregate_base
 * Remove the oldest tuple from an aggregation.
 *
 * This is very much like advance_windowaggregate, except that we will call
 * the inverse transition function (which caller must have checked is
 * available).
 *
 * Returns true if we successfully removed the current row from this
 * aggregate, false if not (in the latter case, caller is responsible
 * for cleaning up by restarting the aggregation).
 */
static bool
advance_windowaggregate_base(WindowAggState *winstate,
							 WindowStatePerFunc perfuncstate,
							 WindowStatePerAgg peraggstate)
{
	LOCAL_FCINFO(fcinfo, FUNC_MAX_ARGS);
	WindowFuncExprState *wfuncstate = perfuncstate->wfuncstate;
	int			numArguments = perfuncstate->numArguments;
	Datum		newVal;
	ListCell   *arg;
	int			i;
	MemoryContext oldContext;
	ExprContext *econtext = winstate->tmpcontext;
	ExprState  *filter = wfuncstate->aggfilter;

	oldContext = MemoryContextSwitchTo(econtext->ecxt_per_tuple_memory);

	/* Skip anything FILTERed out */
	if (filter)
	{
		bool		isnull;
		Datum		res = ExecEvalExpr(filter, econtext, &isnull);

		if (isnull || !DatumGetBool(res))
		{
			MemoryContextSwitchTo(oldContext);
			return true;
		}
	}

	/* We start from 1, since the 0th arg will be the transition value */
	i = 1;
	foreach(arg, wfuncstate->args)
	{
		ExprState  *argstate = (ExprState *) lfirst(arg);

		fcinfo->args[i].value = ExecEvalExpr(argstate, econtext,
											 &fcinfo->args[i].isnull);
		i++;
	}

	if (peraggstate->invtransfn.fn_strict)
	{
		/*
		 * For a strict (inv)transfn, nothing happens when there's a NULL
		 * input; we just keep the prior transValue.  Note transValueCount
		 * doesn't change either.
		 */
		for (i = 1; i <= numArguments; i++)
		{
			if (fcinfo->args[i].isnull)
			{
				MemoryContextSwitchTo(oldContext);
				return true;
			}
		}
	}

	/* There should still be an added but not yet removed value */
	Assert(peraggstate->transValueCount > 0);

	/*
	 * In moving-aggregate mode, the state must never be NULL, except possibly
	 * before any rows have been aggregated (which is surely not the case at
	 * this point).  This restriction allows us to interpret a NULL result
	 * from the inverse function as meaning "sorry, can't do an inverse
	 * transition in this case".  We already checked this in
	 * advance_windowaggregate, but just for safety, check again.
	 */
	if (peraggstate->transValueIsNull)
		elog(ERROR, "aggregate transition value is NULL before inverse transition");

	/*
	 * We mustn't use the inverse transition function to remove the last
	 * input.  Doing so would yield a non-NULL state, whereas we should be in
	 * the initial state afterwards which may very well be NULL.  So instead,
	 * we simply re-initialize the aggregate in this case.
	 */
	if (peraggstate->transValueCount == 1)
	{
		MemoryContextSwitchTo(oldContext);
		initialize_windowaggregate(winstate,
								   &winstate->perfunc[peraggstate->wfuncno],
								   peraggstate);
		return true;
	}

	/*
	 * OK to call the inverse transition function.  Set
	 * winstate->curaggcontext while calling it, for possible use by
	 * AggCheckCallContext.
	 */
	InitFunctionCallInfoData(*fcinfo, &(peraggstate->invtransfn),
							 numArguments + 1,
							 perfuncstate->winCollation,
							 (Node *) winstate, NULL);
	fcinfo->args[0].value = peraggstate->transValue;
	fcinfo->args[0].isnull = peraggstate->transValueIsNull;
	winstate->curaggcontext = peraggstate->aggcontext;
	newVal = FunctionCallInvoke(fcinfo);
	winstate->curaggcontext = NULL;

	/*
	 * If the function returns NULL, report failure, forcing a restart.
	 */
	if (fcinfo->isnull)
	{
		MemoryContextSwitchTo(oldContext);
		return false;
	}

	/* Update number of rows included in transValue */
	peraggstate->transValueCount--;

	/*
	 * If pass-by-ref datatype, must copy the new value into aggcontext and
	 * free the prior transValue.  But if invtransfn returned a pointer to its
	 * first input, we don't need to do anything.  Also, if invtransfn
	 * returned a pointer to a R/W expanded object that is already a child of
	 * the aggcontext, assume we can adopt that value without copying it. (See
	 * comments for ExecAggCopyTransValue, which this code duplicates.)
	 *
	 * Note: the checks for null values here will never fire, but it seems
	 * best to have this stanza look just like advance_windowaggregate.
	 */
	if (!peraggstate->transtypeByVal &&
		DatumGetPointer(newVal) != DatumGetPointer(peraggstate->transValue))
	{
		if (!fcinfo->isnull)
		{
			MemoryContextSwitchTo(peraggstate->aggcontext);
			if (DatumIsReadWriteExpandedObject(newVal,
											   false,
											   peraggstate->transtypeLen) &&
				MemoryContextGetParent(DatumGetEOHP(newVal)->eoh_context) == CurrentMemoryContext)
				 /* do nothing */ ;
			else
				newVal = datumCopy(newVal,
								   peraggstate->transtypeByVal,
								   peraggstate->transtypeLen);
		}
		if (!peraggstate->transValueIsNull)
		{
			if (DatumIsReadWriteExpandedObject(peraggstate->transValue,
											   false,
											   peraggstate->transtypeLen))
				DeleteExpandedObject(peraggstate->transValue);
			else
				pfree(DatumGetPointer(peraggstate->transValue));
		}
	}

	MemoryContextSwitchTo(oldContext);
	peraggstate->transValue = newVal;
	peraggstate->transValueIsNull = fcinfo->isnull;

	return true;
}

/*
 * finalize_windowaggregate
 * parallel to finalize_aggregate in nodeAgg.c
 */
static void
finalize_windowaggregate(WindowAggState *winstate,
						 WindowStatePerFunc perfuncstate,
						 WindowStatePerAgg peraggstate,
						 Datum *result, bool *isnull)
{
	MemoryContext oldContext;

	oldContext = MemoryContextSwitchTo(winstate->ss.ps.ps_ExprContext->ecxt_per_tuple_memory);

	/*
	 * Apply the agg's finalfn if one is provided, else return transValue.
	 */
	if (OidIsValid(peraggstate->finalfn_oid))
	{
		LOCAL_FCINFO(fcinfo, FUNC_MAX_ARGS);
		int			numFinalArgs = peraggstate->numFinalArgs;
		bool		anynull;
		int			i;

		InitFunctionCallInfoData(fcinfodata.fcinfo, &(peraggstate->finalfn),
								 numFinalArgs,
								 perfuncstate->winCollation,
								 (Node *) winstate, NULL);
		fcinfo->args[0].value =
			MakeExpandedObjectReadOnly(peraggstate->transValue,
									   peraggstate->transValueIsNull,
									   peraggstate->transtypeLen);
		fcinfo->args[0].isnull = peraggstate->transValueIsNull;
		anynull = peraggstate->transValueIsNull;

		/* Fill any remaining argument positions with nulls */
		for (i = 1; i < numFinalArgs; i++)
		{
			fcinfo->args[i].value = (Datum) 0;
			fcinfo->args[i].isnull = true;
			anynull = true;
		}

		if (fcinfo->flinfo->fn_strict && anynull)
		{
			/* don't call a strict function with NULL inputs */
			*result = (Datum) 0;
			*isnull = true;
		}
		else
		{
			Datum		res;

			winstate->curaggcontext = peraggstate->aggcontext;
			res = FunctionCallInvoke(fcinfo);
			winstate->curaggcontext = NULL;
			*isnull = fcinfo->isnull;
			*result = MakeExpandedObjectReadOnly(res,
												 fcinfo->isnull,
												 peraggstate->resulttypeLen);
		}
	}
	else
	{
		*result =
			MakeExpandedObjectReadOnly(peraggstate->transValue,
									   peraggstate->transValueIsNull,
									   peraggstate->transtypeLen);
		*isnull = peraggstate->transValueIsNull;
	}

	MemoryContextSwitchTo(oldContext);
}

/*
 * eval_windowaggregates
 * evaluate plain aggregates being used as window functions
 *
 * This differs from nodeAgg.c in two ways.  First, if the window's frame
 * start position moves, we use the inverse transition function (if it exists)
 * to remove rows from the transition value.  And second, we expect to be
 * able to call aggregate final functions repeatedly after aggregating more
 * data onto the same transition value.  This is not a behavior required by
 * nodeAgg.c.
 */
static void
eval_windowaggregates(WindowAggState *winstate)
{
	WindowStatePerAgg peraggstate;
	int			wfuncno,
				numaggs,
				numaggs_restart,
				i;
	int64		aggregatedupto_nonrestarted;
	MemoryContext oldContext;
	ExprContext *econtext;
	WindowObject agg_winobj;
	TupleTableSlot *agg_row_slot;
	TupleTableSlot *temp_slot;

	numaggs = winstate->numaggs;
	if (numaggs == 0)
		return;					/* nothing to do */

	/* final output execution is in ps_ExprContext */
	econtext = winstate->ss.ps.ps_ExprContext;
	agg_winobj = winstate->agg_winobj;
	agg_row_slot = winstate->agg_row_slot;
	temp_slot = winstate->temp_slot_1;

	/*
	 * If the window's frame start clause is UNBOUNDED_PRECEDING and no
	 * exclusion clause is specified, then the window frame consists of a
	 * contiguous group of rows extending forward from the start of the
	 * partition, and rows only enter the frame, never exit it, as the current
	 * row advances forward.  This makes it possible to use an incremental
	 * strategy for evaluating aggregates: we run the transition function for
	 * each row added to the frame, and run the final function whenever we
	 * need the current aggregate value.  This is considerably more efficient
	 * than the naive approach of re-running the entire aggregate calculation
	 * for each current row.  It does assume that the final function doesn't
	 * damage the running transition value, but we have the same assumption in
	 * nodeAgg.c too (when it rescans an existing hash table).
	 *
	 * If the frame start does sometimes move, we can still optimize as above
	 * whenever successive rows share the same frame head, but if the frame
	 * head moves beyond the previous head we try to remove those rows using
	 * the aggregate's inverse transition function.  This function restores
	 * the aggregate's current state to what it would be if the removed row
	 * had never been aggregated in the first place.  Inverse transition
	 * functions may optionally return NULL, indicating that the function was
	 * unable to remove the tuple from aggregation.  If this happens, or if
	 * the aggregate doesn't have an inverse transition function at all, we
	 * must perform the aggregation all over again for all tuples within the
	 * new frame boundaries.
	 *
	 * If there's any exclusion clause, then we may have to aggregate over a
	 * non-contiguous set of rows, so we punt and recalculate for every row.
	 * (For some frame end choices, it might be that the frame is always
	 * contiguous anyway, but that's an optimization to investigate later.)
	 *
	 * In many common cases, multiple rows share the same frame and hence the
	 * same aggregate value. (In particular, if there's no ORDER BY in a RANGE
	 * window, then all rows are peers and so they all have window frame equal
	 * to the whole partition.)  We optimize such cases by calculating the
	 * aggregate value once when we reach the first row of a peer group, and
	 * then returning the saved value for all subsequent rows.
	 *
	 * 'aggregatedupto' keeps track of the first row that has not yet been
	 * accumulated into the aggregate transition values.  Whenever we start a
	 * new peer group, we accumulate forward to the end of the peer group.
	 */

	/*
	 * First, update the frame head position.
	 *
	 * The frame head should never move backwards, and the code below wouldn't
	 * cope if it did, so for safety we complain if it does.
	 */
	update_frameheadpos(winstate);
	if (winstate->frameheadpos < winstate->aggregatedbase)
		elog(ERROR, "window frame head moved backward");

	/*
	 * If the frame didn't change compared to the previous row, we can re-use
	 * the result values that were previously saved at the bottom of this
	 * function.  Since we don't know the current frame's end yet, this is not
	 * possible to check for fully.  But if the frame end mode is UNBOUNDED
	 * FOLLOWING or CURRENT ROW, no exclusion clause is specified, and the
	 * current row lies within the previous row's frame, then the two frames'
	 * ends must coincide.  Note that on the first row aggregatedbase ==
	 * aggregatedupto, meaning this test must fail, so we don't need to check
	 * the "there was no previous row" case explicitly here.
	 */
	if (winstate->aggregatedbase == winstate->frameheadpos &&
		(winstate->frameOptions & (FRAMEOPTION_END_UNBOUNDED_FOLLOWING |
								   FRAMEOPTION_END_CURRENT_ROW)) &&
		!(winstate->frameOptions & FRAMEOPTION_EXCLUSION) &&
		winstate->aggregatedbase <= winstate->currentpos &&
		winstate->aggregatedupto > winstate->currentpos)
	{
		for (i = 0; i < numaggs; i++)
		{
			peraggstate = &winstate->peragg[i];
			wfuncno = peraggstate->wfuncno;
			econtext->ecxt_aggvalues[wfuncno] = peraggstate->resultValue;
			econtext->ecxt_aggnulls[wfuncno] = peraggstate->resultValueIsNull;
		}
		return;
	}

	/*----------
	 * Initialize restart flags.
	 *
	 * We restart the aggregation:
	 *	 - if we're processing the first row in the partition, or
	 *	 - if the frame's head moved and we cannot use an inverse
	 *	   transition function, or
	 *	 - we have an EXCLUSION clause, or
	 *	 - if the new frame doesn't overlap the old one
	 *   - RPR(행 패턴 인식)이 활성화된 경우.  축소된 프레임은 패턴 매칭
	 *     결과에 따라 달라지는데 이 결과는 행마다 완전히 달라질 수 있어
	 *     역전이 최적화를 적용할 수 없기 때문이다
	 *
	 * Note that we don't strictly need to restart in the last case, but if
	 * we're going to remove all rows from the aggregation anyway, a restart
	 * surely is faster.
	 *----------
	 */
	numaggs_restart = 0;
	for (i = 0; i < numaggs; i++)
	{
		peraggstate = &winstate->peragg[i];
		if (winstate->currentpos == 0 ||
			(winstate->aggregatedbase != winstate->frameheadpos &&
			 !OidIsValid(peraggstate->invtransfn_oid)) ||
			(winstate->frameOptions & FRAMEOPTION_EXCLUSION) ||
			winstate->aggregatedupto <= winstate->frameheadpos ||
			rpr_is_defined(winstate))
		{
			peraggstate->restart = true;
			numaggs_restart++;
		}
		else
			peraggstate->restart = false;
	}

	/*
	 * If we have any possibly-moving aggregates, attempt to advance
	 * aggregatedbase to match the frame's head by removing input rows that
	 * fell off the top of the frame from the aggregations.  This can fail,
	 * i.e. advance_windowaggregate_base() can return false, in which case
	 * we'll restart that aggregate below.
	 */
	while (numaggs_restart < numaggs &&
		   winstate->aggregatedbase < winstate->frameheadpos)
	{
		/*
		 * Fetch the next tuple of those being removed. This should never fail
		 * as we should have been here before.
		 */
		if (!window_gettupleslot(agg_winobj, winstate->aggregatedbase,
								 temp_slot))
			elog(ERROR, "could not re-fetch previously fetched frame row");

		/* Set tuple context for evaluation of aggregate arguments */
		winstate->tmpcontext->ecxt_outertuple = temp_slot;

		/*
		 * Perform the inverse transition for each aggregate function in the
		 * window, unless it has already been marked as needing a restart.
		 */
		for (i = 0; i < numaggs; i++)
		{
			bool		ok;

			peraggstate = &winstate->peragg[i];
			if (peraggstate->restart)
				continue;

			wfuncno = peraggstate->wfuncno;
			ok = advance_windowaggregate_base(winstate,
											  &winstate->perfunc[wfuncno],
											  peraggstate);
			if (!ok)
			{
				/* Inverse transition function has failed, must restart */
				peraggstate->restart = true;
				numaggs_restart++;
			}
		}

		/* Reset per-input-tuple context after each tuple */
		ResetExprContext(winstate->tmpcontext);

		/* And advance the aggregated-row state */
		winstate->aggregatedbase++;
		ExecClearTuple(temp_slot);
	}

	/*
	 * If we successfully advanced the base rows of all the aggregates,
	 * aggregatedbase now equals frameheadpos; but if we failed for any, we
	 * must forcibly update aggregatedbase.
	 */
	winstate->aggregatedbase = winstate->frameheadpos;

	/*
	 * If we created a mark pointer for aggregates, keep it pushed up to frame
	 * head, so that tuplestore can discard unnecessary rows.
	 */
	if (agg_winobj->markptr >= 0)
		WinSetMarkPosition(agg_winobj, winstate->frameheadpos);

	/*
	 * Now restart the aggregates that require it.
	 *
	 * We assume that aggregates using the shared context always restart if
	 * *any* aggregate restarts, and we may thus clean up the shared
	 * aggcontext if that is the case.  Private aggcontexts are reset by
	 * initialize_windowaggregate() if their owning aggregate restarts. If we
	 * aren't restarting an aggregate, we need to free any previously saved
	 * result for it, else we'll leak memory.
	 */
	if (numaggs_restart > 0)
		MemoryContextReset(winstate->aggcontext);
	for (i = 0; i < numaggs; i++)
	{
		peraggstate = &winstate->peragg[i];

		/* Aggregates using the shared ctx must restart if *any* agg does */
		Assert(peraggstate->aggcontext != winstate->aggcontext ||
			   numaggs_restart == 0 ||
			   peraggstate->restart);

		if (peraggstate->restart)
		{
			wfuncno = peraggstate->wfuncno;
			initialize_windowaggregate(winstate,
									   &winstate->perfunc[wfuncno],
									   peraggstate);
		}
		else if (!peraggstate->resultValueIsNull)
		{
			if (!peraggstate->resulttypeByVal)
				pfree(DatumGetPointer(peraggstate->resultValue));
			peraggstate->resultValue = (Datum) 0;
			peraggstate->resultValueIsNull = true;
		}
	}

	/*
	 * Non-restarted aggregates now contain the rows between aggregatedbase
	 * (i.e., frameheadpos) and aggregatedupto, while restarted aggregates
	 * contain no rows.  If there are any restarted aggregates, we must thus
	 * begin aggregating anew at frameheadpos, otherwise we may simply
	 * continue at aggregatedupto.  We must remember the old value of
	 * aggregatedupto to know how long to skip advancing non-restarted
	 * aggregates.  If we modify aggregatedupto, we must also clear
	 * agg_row_slot, per the loop invariant below.
	 */
	aggregatedupto_nonrestarted = winstate->aggregatedupto;
	if (numaggs_restart > 0 &&
		winstate->aggregatedupto != winstate->frameheadpos)
	{
		winstate->aggregatedupto = winstate->frameheadpos;
		ExecClearTuple(agg_row_slot);

		/*
		 * RPR 이 정의되어 있으면 aggregatedupto_nonrestarted 를 사용하지
		 * 않는다.  아래의 assertion 오류를 피하기 위해
		 * aggregatedupto_nonrestarted 를 frameheadpos로 재설정한다.
		 */
		if (rpr_is_defined(winstate))
			aggregatedupto_nonrestarted = winstate->frameheadpos;
	}

	/*
	 * Advance until we reach a row not in frame (or end of partition).
	 *
	 * Note the loop invariant: agg_row_slot is either empty or holds the row
	 * at position aggregatedupto.  We advance aggregatedupto after processing
	 * a row.
	 */
	for (;;)
	{
		int64		ret;

		/* Fetch next row if we didn't already */
		if (TupIsNull(agg_row_slot))
		{
			if (!window_gettupleslot(agg_winobj, winstate->aggregatedupto,
									 agg_row_slot))
				break;			/* must be end of partition */
		}

		/*
		 * Exit loop if no more rows can be in frame.  Skip aggregation if
		 * current row is not in frame but there might be more in the frame.
		 */
		ret = row_is_in_frame(agg_winobj, winstate->aggregatedupto,
							  agg_row_slot, false);
		if (ret < 0)
			break;
		if (ret == 0)
			goto next_tuple;

		if (rpr_is_defined(winstate))
		{
			/*
			 * currentpos는 이미 결정되었는데 aggregatedupto가 아직 정해지지
			 * 않았다면, 마지막 축소된 프레임을 이미 지나친 것이다.
			 */
			if (get_reduced_frame_status(winstate, winstate->currentpos)
				!= RF_NOT_DETERMINED &&
				get_reduced_frame_status(winstate, winstate->aggregatedupto)
				== RF_NOT_DETERMINED)
				break;

			/*
			 * aggregatedupto에 대한 축소된 프레임을 계산한다.
			 */
			ret = row_is_in_reduced_frame(winstate->agg_winobj,
										  winstate->aggregatedupto);
			if (ret == -1)		/* 매치되지 않은 행 */
				break;

			/*
			 * 현재 행이 매치 안에 있지만 head가 아니고(건너뛴 행이고), 집계의
			 * 기준 행인지 확인한다.
			 */
			if (get_reduced_frame_status(winstate,
										 winstate->aggregatedupto) == RF_SKIPPED &&
				winstate->aggregatedupto == winstate->aggregatedbase)
				break;
		}

		/* Set tuple context for evaluation of aggregate arguments */
		winstate->tmpcontext->ecxt_outertuple = agg_row_slot;

		/* Accumulate row into the aggregates */
		for (i = 0; i < numaggs; i++)
		{
			peraggstate = &winstate->peragg[i];

			/* Non-restarted aggs skip until aggregatedupto_nonrestarted */
			if (!peraggstate->restart &&
				winstate->aggregatedupto < aggregatedupto_nonrestarted)
				continue;

			wfuncno = peraggstate->wfuncno;
			advance_windowaggregate(winstate,
									&winstate->perfunc[wfuncno],
									peraggstate);
		}

next_tuple:
		/* Reset per-input-tuple context after each tuple */
		ResetExprContext(winstate->tmpcontext);

		/* And advance the aggregated-row state */
		winstate->aggregatedupto++;
		ExecClearTuple(agg_row_slot);
	}

	/* The frame's end is not supposed to move backwards, ever */
	Assert(aggregatedupto_nonrestarted <= winstate->aggregatedupto);

	/*
	 * finalize aggregates and fill result/isnull fields.
	 */
	for (i = 0; i < numaggs; i++)
	{
		Datum	   *result;
		bool	   *isnull;

		peraggstate = &winstate->peragg[i];
		wfuncno = peraggstate->wfuncno;
		result = &econtext->ecxt_aggvalues[wfuncno];
		isnull = &econtext->ecxt_aggnulls[wfuncno];
		finalize_windowaggregate(winstate,
								 &winstate->perfunc[wfuncno],
								 peraggstate,
								 result, isnull);

		/*
		 * save the result in case next row shares the same frame.
		 *
		 * XXX in some framing modes, eg ROWS/END_CURRENT_ROW, we can know in
		 * advance that the next row can't possibly share the same frame. Is
		 * it worth detecting that and skipping this code?
		 */
		if (!peraggstate->resulttypeByVal && !*isnull)
		{
			oldContext = MemoryContextSwitchTo(peraggstate->aggcontext);
			peraggstate->resultValue =
				datumCopy(*result,
						  peraggstate->resulttypeByVal,
						  peraggstate->resulttypeLen);
			MemoryContextSwitchTo(oldContext);
		}
		else
		{
			peraggstate->resultValue = *result;
		}
		peraggstate->resultValueIsNull = *isnull;
	}
}

/*
 * eval_windowfunction
 *
 * Arguments of window functions are not evaluated here, because a window
 * function can need random access to arbitrary rows in the partition.
 * The window function uses the special WinGetFuncArgInPartition and
 * WinGetFuncArgInFrame functions to evaluate the arguments for the rows
 * it wants.
 */
static void
eval_windowfunction(WindowAggState *winstate, WindowStatePerFunc perfuncstate,
					Datum *result, bool *isnull)
{
	LOCAL_FCINFO(fcinfo, FUNC_MAX_ARGS);
	MemoryContext oldContext;

	oldContext = MemoryContextSwitchTo(winstate->ss.ps.ps_ExprContext->ecxt_per_tuple_memory);

	/*
	 * Protect fixed-size fcinfo.  Ordinarily this would have been checked
	 * while creating the WindowFunc, but it's possible that we are looking at
	 * a parsetree from a stored view that was made by a server executable
	 * with a different value of FUNC_MAX_ARGS.
	 */
	if (perfuncstate->numArguments > FUNC_MAX_ARGS)
		ereport(ERROR,
				(errcode(ERRCODE_TOO_MANY_ARGUMENTS),
				 errmsg_plural("cannot pass more than %d argument to a function",
							   "cannot pass more than %d arguments to a function",
							   FUNC_MAX_ARGS,
							   FUNC_MAX_ARGS)));

	/*
	 * We don't pass any normal arguments to a window function, but we do pass
	 * it the number of arguments, in order to permit window function
	 * implementations to support varying numbers of arguments.  The real info
	 * goes through the WindowObject, which is passed via fcinfo->context.
	 */
	InitFunctionCallInfoData(*fcinfo, &(perfuncstate->flinfo),
							 perfuncstate->numArguments,
							 perfuncstate->winCollation,
							 (Node *) perfuncstate->winobj, NULL);
	/* Just in case, make all the regular argument slots be null */
	for (int argno = 0; argno < perfuncstate->numArguments; argno++)
		fcinfo->args[argno].isnull = true;
	/* Window functions don't have a current aggregate context, either */
	winstate->curaggcontext = NULL;

	*result = FunctionCallInvoke(fcinfo);
	*isnull = fcinfo->isnull;

	/*
	 * The window function might have returned a pass-by-ref result that's
	 * just a pointer into one of the WindowObject's temporary slots.  That's
	 * not a problem if it's the only window function using the WindowObject;
	 * but if there's more than one function, we'd better copy the result to
	 * ensure it's not clobbered by later window functions.
	 */
	if (!perfuncstate->resulttypeByVal && !fcinfo->isnull &&
		winstate->numfuncs > 1)
		*result = datumCopy(*result,
							perfuncstate->resulttypeByVal,
							perfuncstate->resulttypeLen);

	MemoryContextSwitchTo(oldContext);
}

/*
 * prepare_tuplestore
 *		Prepare the tuplestore and all of the required read pointers for the
 *		WindowAggState's frameOptions.
 *
 * Note: We use pg_noinline to avoid bloating the calling function with code
 * which is only called once.
 */
static pg_noinline void
prepare_tuplestore(WindowAggState *winstate)
{
	WindowAgg  *node = (WindowAgg *) winstate->ss.ps.plan;
	int			frameOptions = winstate->frameOptions;
	int			numfuncs = winstate->numfuncs;

	/* we shouldn't be called if this was done already */
	Assert(winstate->buffer == NULL);

	/* Create new tuplestore */
	winstate->buffer = tuplestore_begin_heap(false, false, work_mem);

	/*
	 * Set up read pointers for the tuplestore.  The current pointer doesn't
	 * need BACKWARD capability, but the per-window-function read pointers do,
	 * and the aggregate pointer does if we might need to restart aggregation.
	 */
	winstate->current_ptr = 0;	/* read pointer 0 is pre-allocated */

	/* reset default REWIND capability bit for current ptr */
	tuplestore_set_eflags(winstate->buffer, 0);

	/* create read pointers for aggregates, if needed */
	if (winstate->numaggs > 0)
	{
		WindowObject agg_winobj = winstate->agg_winobj;
		int			readptr_flags = 0;

		/*
		 * If the frame head is potentially movable, or we have an EXCLUSION
		 * clause, we might need to restart aggregation ...
		 */
		if (!(frameOptions & FRAMEOPTION_START_UNBOUNDED_PRECEDING) ||
			(frameOptions & FRAMEOPTION_EXCLUSION))
		{
			/* ... so create a mark pointer to track the frame head */
			agg_winobj->markptr = tuplestore_alloc_read_pointer(winstate->buffer, 0);
			/* and the read pointer will need BACKWARD capability */
			readptr_flags |= EXEC_FLAG_BACKWARD;
		}

		agg_winobj->readptr = tuplestore_alloc_read_pointer(winstate->buffer,
															readptr_flags);
	}

	/* create mark and read pointers for each real window function */
	for (int i = 0; i < numfuncs; i++)
	{
		WindowStatePerFunc perfuncstate = &(winstate->perfunc[i]);

		if (!perfuncstate->plain_agg)
		{
			WindowObject winobj = perfuncstate->winobj;

			winobj->markptr = tuplestore_alloc_read_pointer(winstate->buffer,
															0);
			winobj->readptr = tuplestore_alloc_read_pointer(winstate->buffer,
															EXEC_FLAG_BACKWARD);
		}
	}

	/* 필요하면 RPR 내비게이션을 위한 read/mark 포인터를 생성한다 */
	if (winstate->nav_winobj)
	{
		/*
		 * RPR 내비게이션을 위한 mark와 read 포인터를 할당한다.
		 *
		 * 트림 오프셋이 FIXED 이면 (currentpos - navMaxOffset)을 기준으로,
		 * 그리고 경우에 따라 (nfaContext->matchStartRow + navFirstOffset)도
		 * 함께 고려해 mark를 전진시켜, tuplestore_trim()이 더 이상 도달할 수
		 * 없는 행을 해제할 수 있게 한다.  resolve_nav_offsets()는 첫
		 * begin_partition()보다 먼저 실행되므로, 매개변수화된 오프셋이라도
		 * 여기서의 종류는 FIXED 또는 RETAIN_ALL 이다.  RETAIN_ALL 은 트림을
		 * 비활성화한다.
		 *
		 * XXX 하나의 read 포인터가 서로 멀리 떨어진 두 fetch를 담당한다.
		 * rpr_prepare_row()는 NFA 가 전진시키고 있는 frontier 행을 가져오고,
		 * ExecRPRNavGetSlot()은 FIRST 계열을 위해 matchStartRow 근처를
		 * 가져온다.  둘 다 window_gettupleslot()을 거치는데, 이 함수는
		 * seekpos를 기준으로 탐색하므로 두 fetch가 매 행마다 하나의 포인터를
		 * 매치 전체에 걸쳐 끌고 다니게 된다.  메모리 안에서는 이것이 단순한
		 * 포인터 이동이지만, tuplestore가 한 번 스필되면
		 * tuplestore_skiptuples()는 tuple 단위의 테이프 I/O가 되어 비용이 준2
		 * 차적으로 커진다: work_mem 64kB에서 PATTERN (S A+) DEFINE A AS
		 * v >= FIRST(v)는 2,000 행에서 0.84 초, 4,000 행에서 5.4 초, 8,000
		 * 행에서 24.3 초가 걸리는데, 같은 8,000 행을 메모리 안에서 처리하면
		 * 2.6 ms이다.  어느 쪽이든 결과는 동일하다. 이 둘을 분리하려면
		 * match-start 내비게이션을 위한 자신만의 read 포인터를 가진 두 번째
		 * WindowObject 가 필요한데, 이는 이 파일 안에서 해결할 수 있다.
		 */
		winstate->nav_winobj->markptr =
			tuplestore_alloc_read_pointer(winstate->buffer, 0);
		winstate->nav_winobj->readptr =
			tuplestore_alloc_read_pointer(winstate->buffer,
										  EXEC_FLAG_BACKWARD);
	}

	/*
	 * If we are in RANGE or GROUPS mode, then determining frame boundaries
	 * requires physical access to the frame endpoint rows, except in certain
	 * degenerate cases.  We create read pointers to point to those rows, to
	 * simplify access and ensure that the tuplestore doesn't discard the
	 * endpoint rows prematurely.  (Must create pointers in exactly the same
	 * cases that update_frameheadpos and update_frametailpos need them.)
	 */
	winstate->framehead_ptr = winstate->frametail_ptr = -1; /* if not used */

	if (frameOptions & (FRAMEOPTION_RANGE | FRAMEOPTION_GROUPS))
	{
		if (((frameOptions & FRAMEOPTION_START_CURRENT_ROW) &&
			 node->ordNumCols != 0) ||
			(frameOptions & FRAMEOPTION_START_OFFSET))
			winstate->framehead_ptr =
				tuplestore_alloc_read_pointer(winstate->buffer, 0);
		if (((frameOptions & FRAMEOPTION_END_CURRENT_ROW) &&
			 node->ordNumCols != 0) ||
			(frameOptions & FRAMEOPTION_END_OFFSET))
			winstate->frametail_ptr =
				tuplestore_alloc_read_pointer(winstate->buffer, 0);
	}

	/*
	 * If we have an exclusion clause that requires knowing the boundaries of
	 * the current row's peer group, we create a read pointer to track the
	 * tail position of the peer group (i.e., first row of the next peer
	 * group).  The head position does not require its own pointer because we
	 * maintain that as a side effect of advancing the current row.
	 */
	winstate->grouptail_ptr = -1;

	if ((frameOptions & (FRAMEOPTION_EXCLUDE_GROUP |
						 FRAMEOPTION_EXCLUDE_TIES)) &&
		node->ordNumCols != 0)
	{
		winstate->grouptail_ptr =
			tuplestore_alloc_read_pointer(winstate->buffer, 0);
	}
}

/*
 * begin_partition
 * Start buffering rows of the next partition.
 */
static void
begin_partition(WindowAggState *winstate)
{
	PlanState  *outerPlan = outerPlanState(winstate);
	int			numfuncs = winstate->numfuncs;

	winstate->partition_spooled = false;
	winstate->framehead_valid = false;
	winstate->frametail_valid = false;
	winstate->grouptail_valid = false;
	if (rpr_is_defined(winstate))
		clear_reduced_frame(winstate);
	winstate->spooled_rows = 0;
	winstate->currentpos = 0;
	winstate->frameheadpos = 0;
	winstate->frametailpos = 0;
	winstate->currentgroup = 0;
	winstate->frameheadgroup = 0;
	winstate->frametailgroup = 0;
	winstate->groupheadpos = 0;
	winstate->grouptailpos = -1;	/* see update_grouptailpos */
	ExecClearTuple(winstate->agg_row_slot);
	if (winstate->framehead_slot)
		ExecClearTuple(winstate->framehead_slot);
	if (winstate->frametail_slot)
		ExecClearTuple(winstate->frametail_slot);

	/*
	 * If this is the very first partition, we need to fetch the first input
	 * row to store in first_part_slot.
	 */
	if (TupIsNull(winstate->first_part_slot))
	{
		TupleTableSlot *outerslot = ExecProcNode(outerPlan);

		if (!TupIsNull(outerslot))
			ExecCopySlot(winstate->first_part_slot, outerslot);
		else
		{
			/* outer plan is empty, so we have nothing to do */
			winstate->partition_spooled = true;
			winstate->more_partitions = false;
			return;
		}
	}

	/* Create new tuplestore if not done already. */
	if (unlikely(winstate->buffer == NULL))
		prepare_tuplestore(winstate);

	winstate->next_partition = false;

	if (winstate->numaggs > 0)
	{
		WindowObject agg_winobj = winstate->agg_winobj;

		/* reset mark and see positions for aggregate functions */
		agg_winobj->markpos = -1;
		agg_winobj->seekpos = -1;

		/* Also reset the row counters for aggregates */
		winstate->aggregatedbase = 0;
		winstate->aggregatedupto = 0;
	}

	/* RPR 내비게이션을 위해 mark와 seek 위치를 재설정한다 */
	if (winstate->nav_winobj)
	{
		winstate->nav_winobj->markpos = -1;
		winstate->nav_winobj->seekpos = -1;
	}

	/* reset mark and seek positions for each real window function */
	for (int i = 0; i < numfuncs; i++)
	{
		WindowStatePerFunc perfuncstate = &(winstate->perfunc[i]);

		if (!perfuncstate->plain_agg)
		{
			WindowObject winobj = perfuncstate->winobj;

			winobj->markpos = -1;
			winobj->seekpos = -1;

			/* reset null map */
			if (winobj->ignore_nulls == IGNORE_NULLS ||
				winobj->ignore_nulls == PARSER_IGNORE_NULLS)
			{
				int			numargs = perfuncstate->numArguments;

				for (int j = 0; j < numargs; j++)
				{
					int			n = winobj->num_notnull_info[j];

					if (n > 0)
						memset(winobj->notnull_info[j], 0,
							   NN_POS_TO_BYTES(n));
				}
			}
		}
	}

	/*
	 * Store the first tuple into the tuplestore (it's always available now;
	 * we either read it above, or saved it at the end of previous partition)
	 */
	tuplestore_puttupleslot(winstate->buffer, winstate->first_part_slot);
	winstate->spooled_rows++;
}

/*
 * Read tuples from the outer node, up to and including position 'pos', and
 * store them into the tuplestore. If pos is -1, reads the whole partition.
 */
static void
spool_tuples(WindowAggState *winstate, int64 pos)
{
	WindowAgg  *node = (WindowAgg *) winstate->ss.ps.plan;
	PlanState  *outerPlan;
	TupleTableSlot *outerslot;
	MemoryContext oldcontext;

	if (!winstate->buffer)
		return;					/* just a safety check */
	if (winstate->partition_spooled)
		return;					/* whole partition done already */

	/*
	 * When in pass-through mode we can just exhaust all tuples in the current
	 * partition.  We don't need these tuples for any further window function
	 * evaluation, however, we do need to keep them around if we're not the
	 * top-level window as another WindowAgg node above must see these.
	 */
	if (winstate->status != WINDOWAGG_RUN)
	{
		Assert(winstate->status == WINDOWAGG_PASSTHROUGH ||
			   winstate->status == WINDOWAGG_PASSTHROUGH_STRICT);

		pos = -1;
	}

	/*
	 * If the tuplestore has spilled to disk, alternate reading and writing
	 * becomes quite expensive due to frequent buffer flushes.  It's cheaper
	 * to force the entire partition to get spooled in one go.
	 *
	 * XXX this is a horrid kluge --- it'd be better to fix the performance
	 * problem inside tuplestore.  FIXME
	 */
	else if (!tuplestore_in_memory(winstate->buffer))
		pos = -1;

	outerPlan = outerPlanState(winstate);

	/* Must be in query context to call outerplan */
	oldcontext = MemoryContextSwitchTo(winstate->ss.ps.ps_ExprContext->ecxt_per_query_memory);

	while (winstate->spooled_rows <= pos || pos == -1)
	{
		outerslot = ExecProcNode(outerPlan);
		if (TupIsNull(outerslot))
		{
			/* reached the end of the last partition */
			winstate->partition_spooled = true;
			winstate->more_partitions = false;
			break;
		}

		if (node->partNumCols > 0)
		{
			ExprContext *econtext = winstate->tmpcontext;

			econtext->ecxt_innertuple = winstate->first_part_slot;
			econtext->ecxt_outertuple = outerslot;

			/* Check if this tuple still belongs to the current partition */
			if (!ExecQualAndReset(winstate->partEqfunction, econtext))
			{
				/*
				 * end of partition; copy the tuple for the next cycle.
				 */
				ExecCopySlot(winstate->first_part_slot, outerslot);
				winstate->partition_spooled = true;
				winstate->more_partitions = true;
				break;
			}
		}

		/*
		 * Remember the tuple unless we're the top-level window and we're in
		 * pass-through mode.
		 */
		if (winstate->status != WINDOWAGG_PASSTHROUGH_STRICT)
		{
			/* Still in partition, so save it into the tuplestore */
			tuplestore_puttupleslot(winstate->buffer, outerslot);
			winstate->spooled_rows++;
		}
	}

	MemoryContextSwitchTo(oldcontext);
}

/*
 * release_partition
 * clear information kept within a partition, including
 * tuplestore and aggregate results.
 */
static void
release_partition(WindowAggState *winstate)
{
	int			i;

	for (i = 0; i < winstate->numfuncs; i++)
	{
		WindowStatePerFunc perfuncstate = &(winstate->perfunc[i]);

		/* Release any partition-local state of this window function */
		if (perfuncstate->winobj)
			perfuncstate->winobj->localmem = NULL;
	}

	/*
	 * Release all partition-local memory (in particular, any partition-local
	 * state that we might have trashed our pointers to in the above loop, and
	 * any aggregate temp data).  We don't rely on retail pfree because some
	 * aggregates might have allocated data we don't have direct pointers to.
	 */
	MemoryContextReset(winstate->partcontext);
	MemoryContextReset(winstate->aggcontext);
	for (i = 0; i < winstate->numaggs; i++)
	{
		if (winstate->peragg[i].aggcontext != winstate->aggcontext)
			MemoryContextReset(winstate->peragg[i].aggcontext);
	}

	if (winstate->buffer)
		tuplestore_clear(winstate->buffer);
	winstate->partition_spooled = false;
	winstate->next_partition = true;

	/* RPR 매치 결과를 재설정한다 */
	clear_reduced_frame(winstate);

	/* 새 파티션을 위해 NFA 상태를 재설정한다 */
	winstate->nfaContext = NULL;
	winstate->nfaContextTail = NULL;
	winstate->nfaContextFree = NULL;
	winstate->nfaStateFree = NULL;
	winstate->nfaLastProcessedRow = -1;
	winstate->nfaStatesActive = 0;
	winstate->nfaContextsActive = 0;

	/* 새 파티션을 위해 nav 슬롯 위치 캐시를 무효화한다. */
	winstate->nav_slot_pos = -1;
}

/*
 * row_is_in_frame
 * Determine whether a row is in the current row's window frame according
 * to our window framing rule
 *
 * The caller must have already determined that the row is in the partition
 * and fetched it into a slot if fetch_tuple is false.
 * This function just encapsulates the framing rules.
 *
 * Returns:
 * -1, if the row is out of frame and no succeeding rows can be in frame
 * 0, if the row is out of frame but succeeding rows might be in frame
 * 1, if the row is in frame
 *
 * May clobber winstate->temp_slot_2.
 */
static int
row_is_in_frame(WindowObject winobj, int64 pos, TupleTableSlot *slot,
				bool fetch_tuple)
{
	WindowAggState *winstate = winobj->winstate;
	int			frameOptions = winstate->frameOptions;

	Assert(pos >= 0);			/* else caller error */

	/*
	 * First, check frame starting conditions.  We might as well delegate this
	 * to update_frameheadpos always; it doesn't add any notable cost.
	 */
	update_frameheadpos(winstate);
	if (pos < winstate->frameheadpos)
		return 0;

	/*
	 * Okay so far, now check frame ending conditions.  Here, we avoid calling
	 * update_frametailpos in simple cases, so as not to spool tuples further
	 * ahead than necessary.
	 */
	if (frameOptions & FRAMEOPTION_END_CURRENT_ROW)
	{
		if (frameOptions & FRAMEOPTION_ROWS)
		{
			/* rows after current row are out of frame */
			if (pos > winstate->currentpos)
				return -1;
		}
		else if (frameOptions & (FRAMEOPTION_RANGE | FRAMEOPTION_GROUPS))
		{
			/* following row that is not peer is out of frame */
			if (pos > winstate->currentpos)
			{
				if (fetch_tuple)	/* need to fetch tuple? */
					if (!window_gettupleslot(winobj, pos, slot))
						return -1;
				if (!are_peers(winstate, slot, winstate->ss.ss_ScanTupleSlot))
					return -1;
			}
		}
		else
			Assert(false);
	}
	else if (frameOptions & FRAMEOPTION_END_OFFSET)
	{
		if (frameOptions & FRAMEOPTION_ROWS)
		{
			int64		offset = DatumGetInt64(winstate->endOffsetValue);
			int64		frameendpos = 0;

			/* rows after current row + offset are out of frame */
			if (frameOptions & FRAMEOPTION_END_OFFSET_PRECEDING)
				offset = -offset;

			/*
			 * If we have an overflow, it means the frame end is beyond the
			 * range of int64.  Since currentpos >= 0, this can only be a
			 * positive overflow.  We treat this as meaning that the frame
			 * extends to end of partition.
			 */
			if (!pg_add_s64_overflow(winstate->currentpos, offset,
									 &frameendpos) &&
				pos > frameendpos)
				return -1;
		}
		else if (frameOptions & (FRAMEOPTION_RANGE | FRAMEOPTION_GROUPS))
		{
			/* hard cases, so delegate to update_frametailpos */
			update_frametailpos(winstate);
			if (pos >= winstate->frametailpos)
				return -1;
		}
		else
			Assert(false);
	}

	/* Check exclusion clause */
	if (frameOptions & FRAMEOPTION_EXCLUDE_CURRENT_ROW)
	{
		if (pos == winstate->currentpos)
			return 0;
	}
	else if ((frameOptions & FRAMEOPTION_EXCLUDE_GROUP) ||
			 ((frameOptions & FRAMEOPTION_EXCLUDE_TIES) &&
			  pos != winstate->currentpos))
	{
		WindowAgg  *node = (WindowAgg *) winstate->ss.ps.plan;

		/* If no ORDER BY, all rows are peers with each other */
		if (node->ordNumCols == 0)
			return 0;
		/* Otherwise, check the group boundaries */
		if (pos >= winstate->groupheadpos)
		{
			update_grouptailpos(winstate);
			if (pos < winstate->grouptailpos)
				return 0;
		}
	}

	/* If we get here, it's in frame */
	return 1;
}

/*
 * update_frameheadpos
 * make frameheadpos valid for the current row
 *
 * Note that frameheadpos is computed without regard for any window exclusion
 * clause; the current row and/or its peers are considered part of the frame
 * for this purpose even if they must be excluded later.
 *
 * May clobber winstate->temp_slot_2.
 */
static void
update_frameheadpos(WindowAggState *winstate)
{
	WindowAgg  *node = (WindowAgg *) winstate->ss.ps.plan;
	int			frameOptions = winstate->frameOptions;
	MemoryContext oldcontext;

	if (winstate->framehead_valid)
		return;					/* already known for current row */

	/* We may be called in a short-lived context */
	oldcontext = MemoryContextSwitchTo(winstate->ss.ps.ps_ExprContext->ecxt_per_query_memory);

	if (frameOptions & FRAMEOPTION_START_UNBOUNDED_PRECEDING)
	{
		/* In UNBOUNDED PRECEDING mode, frame head is always row 0 */
		winstate->frameheadpos = 0;
		winstate->framehead_valid = true;
	}
	else if (frameOptions & FRAMEOPTION_START_CURRENT_ROW)
	{
		if (frameOptions & FRAMEOPTION_ROWS)
		{
			/* In ROWS mode, frame head is the same as current */
			winstate->frameheadpos = winstate->currentpos;
			winstate->framehead_valid = true;
		}
		else if (frameOptions & (FRAMEOPTION_RANGE | FRAMEOPTION_GROUPS))
		{
			/* If no ORDER BY, all rows are peers with each other */
			if (node->ordNumCols == 0)
			{
				winstate->frameheadpos = 0;
				winstate->framehead_valid = true;
				MemoryContextSwitchTo(oldcontext);
				return;
			}

			/*
			 * In RANGE or GROUPS START_CURRENT_ROW mode, frame head is the
			 * first row that is a peer of current row.  We keep a copy of the
			 * last-known frame head row in framehead_slot, and advance as
			 * necessary.  Note that if we reach end of partition, we will
			 * leave frameheadpos = end+1 and framehead_slot empty.
			 */
			tuplestore_select_read_pointer(winstate->buffer,
										   winstate->framehead_ptr);
			if (winstate->frameheadpos == 0 &&
				TupIsNull(winstate->framehead_slot))
			{
				/* fetch first row into framehead_slot, if we didn't already */
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->framehead_slot))
					elog(ERROR, "unexpected end of tuplestore");
			}

			while (!TupIsNull(winstate->framehead_slot))
			{
				if (are_peers(winstate, winstate->framehead_slot,
							  winstate->ss.ss_ScanTupleSlot))
					break;		/* this row is the correct frame head */
				/* Note we advance frameheadpos even if the fetch fails */
				winstate->frameheadpos++;
				spool_tuples(winstate, winstate->frameheadpos);
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->framehead_slot))
					break;		/* end of partition */
			}
			winstate->framehead_valid = true;
		}
		else
			Assert(false);
	}
	else if (frameOptions & FRAMEOPTION_START_OFFSET)
	{
		if (frameOptions & FRAMEOPTION_ROWS)
		{
			/* In ROWS mode, bound is physically n before/after current */
			int64		offset = DatumGetInt64(winstate->startOffsetValue);

			if (frameOptions & FRAMEOPTION_START_OFFSET_PRECEDING)
				offset = -offset;

			/*
			 * If we have an overflow, it means the frame head is beyond the
			 * range of int64.  Since currentpos >= 0, this can only be a
			 * positive overflow.  We treat this as being beyond end of
			 * partition.
			 */
			if (pg_add_s64_overflow(winstate->currentpos, offset,
									&winstate->frameheadpos))
				winstate->frameheadpos = PG_INT64_MAX;

			/* frame head can't go before first row */
			if (winstate->frameheadpos < 0)
				winstate->frameheadpos = 0;
			else if (winstate->frameheadpos > winstate->currentpos + 1)
			{
				/* make sure frameheadpos is not past end of partition */
				spool_tuples(winstate, winstate->frameheadpos - 1);
				if (winstate->frameheadpos > winstate->spooled_rows)
					winstate->frameheadpos = winstate->spooled_rows;
			}
			winstate->framehead_valid = true;
		}
		else if (frameOptions & FRAMEOPTION_RANGE)
		{
			/*
			 * In RANGE START_OFFSET mode, frame head is the first row that
			 * satisfies the in_range constraint relative to the current row.
			 * We keep a copy of the last-known frame head row in
			 * framehead_slot, and advance as necessary.  Note that if we
			 * reach end of partition, we will leave frameheadpos = end+1 and
			 * framehead_slot empty.
			 */
			int			sortCol = node->ordColIdx[0];
			bool		sub,
						less;

			/* We must have an ordering column */
			Assert(node->ordNumCols == 1);

			/* Precompute flags for in_range checks */
			if (frameOptions & FRAMEOPTION_START_OFFSET_PRECEDING)
				sub = true;		/* subtract startOffset from current row */
			else
				sub = false;	/* add it */
			less = false;		/* normally, we want frame head >= sum */
			/* If sort order is descending, flip both flags */
			if (!winstate->inRangeAsc)
			{
				sub = !sub;
				less = true;
			}

			tuplestore_select_read_pointer(winstate->buffer,
										   winstate->framehead_ptr);
			if (winstate->frameheadpos == 0 &&
				TupIsNull(winstate->framehead_slot))
			{
				/* fetch first row into framehead_slot, if we didn't already */
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->framehead_slot))
					elog(ERROR, "unexpected end of tuplestore");
			}

			while (!TupIsNull(winstate->framehead_slot))
			{
				Datum		headval,
							currval;
				bool		headisnull,
							currisnull;

				headval = slot_getattr(winstate->framehead_slot, sortCol,
									   &headisnull);
				currval = slot_getattr(winstate->ss.ss_ScanTupleSlot, sortCol,
									   &currisnull);
				if (headisnull || currisnull)
				{
					/* order of the rows depends only on nulls_first */
					if (winstate->inRangeNullsFirst)
					{
						/* advance head if head is null and curr is not */
						if (!headisnull || currisnull)
							break;
					}
					else
					{
						/* advance head if head is not null and curr is null */
						if (headisnull || !currisnull)
							break;
					}
				}
				else
				{
					if (DatumGetBool(FunctionCall5Coll(&winstate->startInRangeFunc,
													   winstate->inRangeColl,
													   headval,
													   currval,
													   winstate->startOffsetValue,
													   BoolGetDatum(sub),
													   BoolGetDatum(less))))
						break;	/* this row is the correct frame head */
				}
				/* Note we advance frameheadpos even if the fetch fails */
				winstate->frameheadpos++;
				spool_tuples(winstate, winstate->frameheadpos);
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->framehead_slot))
					break;		/* end of partition */
			}
			winstate->framehead_valid = true;
		}
		else if (frameOptions & FRAMEOPTION_GROUPS)
		{
			/*
			 * In GROUPS START_OFFSET mode, frame head is the first row of the
			 * first peer group whose number satisfies the offset constraint.
			 * We keep a copy of the last-known frame head row in
			 * framehead_slot, and advance as necessary.  Note that if we
			 * reach end of partition, we will leave frameheadpos = end+1 and
			 * framehead_slot empty.
			 */
			int64		offset = DatumGetInt64(winstate->startOffsetValue);
			int64		minheadgroup = 0;

			if (frameOptions & FRAMEOPTION_START_OFFSET_PRECEDING)
				minheadgroup = winstate->currentgroup - offset;
			else
			{
				/*
				 * If we have an overflow, it means the target group is beyond
				 * the range of int64.  We treat this as "infinity", which
				 * ensures the loop below advances to end of partition.
				 */
				if (pg_add_s64_overflow(winstate->currentgroup, offset,
										&minheadgroup))
					minheadgroup = PG_INT64_MAX;
			}

			tuplestore_select_read_pointer(winstate->buffer,
										   winstate->framehead_ptr);
			if (winstate->frameheadpos == 0 &&
				TupIsNull(winstate->framehead_slot))
			{
				/* fetch first row into framehead_slot, if we didn't already */
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->framehead_slot))
					elog(ERROR, "unexpected end of tuplestore");
			}

			while (!TupIsNull(winstate->framehead_slot))
			{
				if (winstate->frameheadgroup >= minheadgroup)
					break;		/* this row is the correct frame head */
				ExecCopySlot(winstate->temp_slot_2, winstate->framehead_slot);
				/* Note we advance frameheadpos even if the fetch fails */
				winstate->frameheadpos++;
				spool_tuples(winstate, winstate->frameheadpos);
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->framehead_slot))
					break;		/* end of partition */
				if (!are_peers(winstate, winstate->temp_slot_2,
							   winstate->framehead_slot))
					winstate->frameheadgroup++;
			}
			ExecClearTuple(winstate->temp_slot_2);
			winstate->framehead_valid = true;
		}
		else
			Assert(false);
	}
	else
		Assert(false);

	MemoryContextSwitchTo(oldcontext);
}

/*
 * update_frametailpos
 * make frametailpos valid for the current row
 *
 * Note that frametailpos is computed without regard for any window exclusion
 * clause; the current row and/or its peers are considered part of the frame
 * for this purpose even if they must be excluded later.
 *
 * May clobber winstate->temp_slot_2.
 */
static void
update_frametailpos(WindowAggState *winstate)
{
	WindowAgg  *node = (WindowAgg *) winstate->ss.ps.plan;
	int			frameOptions = winstate->frameOptions;
	MemoryContext oldcontext;

	if (winstate->frametail_valid)
		return;					/* already known for current row */

	/* We may be called in a short-lived context */
	oldcontext = MemoryContextSwitchTo(winstate->ss.ps.ps_ExprContext->ecxt_per_query_memory);

	if (frameOptions & FRAMEOPTION_END_UNBOUNDED_FOLLOWING)
	{
		/* In UNBOUNDED FOLLOWING mode, all partition rows are in frame */
		spool_tuples(winstate, -1);
		winstate->frametailpos = winstate->spooled_rows;
		winstate->frametail_valid = true;
	}
	else if (frameOptions & FRAMEOPTION_END_CURRENT_ROW)
	{
		if (frameOptions & FRAMEOPTION_ROWS)
		{
			/* In ROWS mode, exactly the rows up to current are in frame */
			winstate->frametailpos = winstate->currentpos + 1;
			winstate->frametail_valid = true;
		}
		else if (frameOptions & (FRAMEOPTION_RANGE | FRAMEOPTION_GROUPS))
		{
			/* If no ORDER BY, all rows are peers with each other */
			if (node->ordNumCols == 0)
			{
				spool_tuples(winstate, -1);
				winstate->frametailpos = winstate->spooled_rows;
				winstate->frametail_valid = true;
				MemoryContextSwitchTo(oldcontext);
				return;
			}

			/*
			 * In RANGE or GROUPS END_CURRENT_ROW mode, frame end is the last
			 * row that is a peer of current row, frame tail is the row after
			 * that (if any).  We keep a copy of the last-known frame tail row
			 * in frametail_slot, and advance as necessary.  Note that if we
			 * reach end of partition, we will leave frametailpos = end+1 and
			 * frametail_slot empty.
			 */
			tuplestore_select_read_pointer(winstate->buffer,
										   winstate->frametail_ptr);
			if (winstate->frametailpos == 0 &&
				TupIsNull(winstate->frametail_slot))
			{
				/* fetch first row into frametail_slot, if we didn't already */
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->frametail_slot))
					elog(ERROR, "unexpected end of tuplestore");
			}

			while (!TupIsNull(winstate->frametail_slot))
			{
				if (winstate->frametailpos > winstate->currentpos &&
					!are_peers(winstate, winstate->frametail_slot,
							   winstate->ss.ss_ScanTupleSlot))
					break;		/* this row is the frame tail */
				/* Note we advance frametailpos even if the fetch fails */
				winstate->frametailpos++;
				spool_tuples(winstate, winstate->frametailpos);
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->frametail_slot))
					break;		/* end of partition */
			}
			winstate->frametail_valid = true;
		}
		else
			Assert(false);
	}
	else if (frameOptions & FRAMEOPTION_END_OFFSET)
	{
		if (frameOptions & FRAMEOPTION_ROWS)
		{
			/* In ROWS mode, bound is physically n before/after current */
			int64		offset = DatumGetInt64(winstate->endOffsetValue);

			if (frameOptions & FRAMEOPTION_END_OFFSET_PRECEDING)
				offset = -offset;

			/*
			 * If we have an overflow, it means the frame tail is beyond the
			 * range of int64.  Since currentpos >= 0, this can only be a
			 * positive overflow.  We treat this as being beyond end of
			 * partition.
			 */
			if (pg_add_s64_overflow(winstate->currentpos, offset,
									&winstate->frametailpos) ||
				pg_add_s64_overflow(winstate->frametailpos, 1,
									&winstate->frametailpos))
				winstate->frametailpos = PG_INT64_MAX;

			/* smallest allowable value of frametailpos is 0 */
			if (winstate->frametailpos < 0)
				winstate->frametailpos = 0;
			else if (winstate->frametailpos > winstate->currentpos + 1)
			{
				/* make sure frametailpos is not past end of partition */
				spool_tuples(winstate, winstate->frametailpos - 1);
				if (winstate->frametailpos > winstate->spooled_rows)
					winstate->frametailpos = winstate->spooled_rows;
			}
			winstate->frametail_valid = true;
		}
		else if (frameOptions & FRAMEOPTION_RANGE)
		{
			/*
			 * In RANGE END_OFFSET mode, frame end is the last row that
			 * satisfies the in_range constraint relative to the current row,
			 * frame tail is the row after that (if any).  We keep a copy of
			 * the last-known frame tail row in frametail_slot, and advance as
			 * necessary.  Note that if we reach end of partition, we will
			 * leave frametailpos = end+1 and frametail_slot empty.
			 */
			int			sortCol = node->ordColIdx[0];
			bool		sub,
						less;

			/* We must have an ordering column */
			Assert(node->ordNumCols == 1);

			/* Precompute flags for in_range checks */
			if (frameOptions & FRAMEOPTION_END_OFFSET_PRECEDING)
				sub = true;		/* subtract endOffset from current row */
			else
				sub = false;	/* add it */
			less = true;		/* normally, we want frame tail <= sum */
			/* If sort order is descending, flip both flags */
			if (!winstate->inRangeAsc)
			{
				sub = !sub;
				less = false;
			}

			tuplestore_select_read_pointer(winstate->buffer,
										   winstate->frametail_ptr);
			if (winstate->frametailpos == 0 &&
				TupIsNull(winstate->frametail_slot))
			{
				/* fetch first row into frametail_slot, if we didn't already */
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->frametail_slot))
					elog(ERROR, "unexpected end of tuplestore");
			}

			while (!TupIsNull(winstate->frametail_slot))
			{
				Datum		tailval,
							currval;
				bool		tailisnull,
							currisnull;

				tailval = slot_getattr(winstate->frametail_slot, sortCol,
									   &tailisnull);
				currval = slot_getattr(winstate->ss.ss_ScanTupleSlot, sortCol,
									   &currisnull);
				if (tailisnull || currisnull)
				{
					/* order of the rows depends only on nulls_first */
					if (winstate->inRangeNullsFirst)
					{
						/* advance tail if tail is null or curr is not */
						if (!tailisnull)
							break;
					}
					else
					{
						/* advance tail if tail is not null or curr is null */
						if (!currisnull)
							break;
					}
				}
				else
				{
					if (!DatumGetBool(FunctionCall5Coll(&winstate->endInRangeFunc,
														winstate->inRangeColl,
														tailval,
														currval,
														winstate->endOffsetValue,
														BoolGetDatum(sub),
														BoolGetDatum(less))))
						break;	/* this row is the correct frame tail */
				}
				/* Note we advance frametailpos even if the fetch fails */
				winstate->frametailpos++;
				spool_tuples(winstate, winstate->frametailpos);
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->frametail_slot))
					break;		/* end of partition */
			}
			winstate->frametail_valid = true;
		}
		else if (frameOptions & FRAMEOPTION_GROUPS)
		{
			/*
			 * In GROUPS END_OFFSET mode, frame end is the last row of the
			 * last peer group whose number satisfies the offset constraint,
			 * and frame tail is the row after that (if any).  We keep a copy
			 * of the last-known frame tail row in frametail_slot, and advance
			 * as necessary.  Note that if we reach end of partition, we will
			 * leave frametailpos = end+1 and frametail_slot empty.
			 */
			int64		offset = DatumGetInt64(winstate->endOffsetValue);
			int64		maxtailgroup = 0;

			if (frameOptions & FRAMEOPTION_END_OFFSET_PRECEDING)
				maxtailgroup = winstate->currentgroup - offset;
			else
			{
				/*
				 * If we have an overflow, it means the target group is beyond
				 * the range of int64.  We treat this as "infinity", which
				 * ensures the loop below advances to end of partition.
				 */
				if (pg_add_s64_overflow(winstate->currentgroup, offset,
										&maxtailgroup))
					maxtailgroup = PG_INT64_MAX;
			}

			tuplestore_select_read_pointer(winstate->buffer,
										   winstate->frametail_ptr);
			if (winstate->frametailpos == 0 &&
				TupIsNull(winstate->frametail_slot))
			{
				/* fetch first row into frametail_slot, if we didn't already */
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->frametail_slot))
					elog(ERROR, "unexpected end of tuplestore");
			}

			while (!TupIsNull(winstate->frametail_slot))
			{
				if (winstate->frametailgroup > maxtailgroup)
					break;		/* this row is the correct frame tail */
				ExecCopySlot(winstate->temp_slot_2, winstate->frametail_slot);
				/* Note we advance frametailpos even if the fetch fails */
				winstate->frametailpos++;
				spool_tuples(winstate, winstate->frametailpos);
				if (!tuplestore_gettupleslot(winstate->buffer, true, true,
											 winstate->frametail_slot))
					break;		/* end of partition */
				if (!are_peers(winstate, winstate->temp_slot_2,
							   winstate->frametail_slot))
					winstate->frametailgroup++;
			}
			ExecClearTuple(winstate->temp_slot_2);
			winstate->frametail_valid = true;
		}
		else
			Assert(false);
	}
	else
		Assert(false);

	MemoryContextSwitchTo(oldcontext);
}

/*
 * update_grouptailpos
 * make grouptailpos valid for the current row
 *
 * May clobber winstate->temp_slot_2.
 */
static void
update_grouptailpos(WindowAggState *winstate)
{
	WindowAgg  *node = (WindowAgg *) winstate->ss.ps.plan;
	MemoryContext oldcontext;

	if (winstate->grouptail_valid)
		return;					/* already known for current row */

	/* We may be called in a short-lived context */
	oldcontext = MemoryContextSwitchTo(winstate->ss.ps.ps_ExprContext->ecxt_per_query_memory);

	/* If no ORDER BY, all rows are peers with each other */
	if (node->ordNumCols == 0)
	{
		spool_tuples(winstate, -1);
		winstate->grouptailpos = winstate->spooled_rows;
		winstate->grouptail_valid = true;
		MemoryContextSwitchTo(oldcontext);
		return;
	}

	/*
	 * Because grouptail_valid is reset only when current row advances into a
	 * new peer group, we always reach here knowing that grouptailpos needs to
	 * be advanced by at least one row.  Hence, unlike the otherwise similar
	 * case for frame tail tracking, we do not need persistent storage of the
	 * group tail row.
	 */
	Assert(winstate->grouptailpos <= winstate->currentpos);
	tuplestore_select_read_pointer(winstate->buffer,
								   winstate->grouptail_ptr);
	for (;;)
	{
		/* Note we advance grouptailpos even if the fetch fails */
		winstate->grouptailpos++;
		spool_tuples(winstate, winstate->grouptailpos);
		if (!tuplestore_gettupleslot(winstate->buffer, true, true,
									 winstate->temp_slot_2))
			break;				/* end of partition */
		if (winstate->grouptailpos > winstate->currentpos &&
			!are_peers(winstate, winstate->temp_slot_2,
					   winstate->ss.ss_ScanTupleSlot))
			break;				/* this row is the group tail */
	}
	ExecClearTuple(winstate->temp_slot_2);
	winstate->grouptail_valid = true;

	MemoryContextSwitchTo(oldcontext);
}

/*
 * calculate_frame_offsets
 *		Determine the startOffsetValue and endOffsetValue values for the
 *		WindowAgg's frame options.
 */
static pg_noinline void
calculate_frame_offsets(PlanState *pstate)
{
	WindowAggState *winstate = castNode(WindowAggState, pstate);
	ExprContext *econtext;
	int			frameOptions = winstate->frameOptions;
	Datum		value;
	bool		isnull;
	int16		len;
	bool		byval;

	/* Ensure we've not been called before for this scan */
	Assert(winstate->all_first);

	econtext = winstate->ss.ps.ps_ExprContext;

	if (frameOptions & FRAMEOPTION_START_OFFSET)
	{
		Assert(winstate->startOffset != NULL);
		value = ExecEvalExprSwitchContext(winstate->startOffset,
										  econtext,
										  &isnull);
		if (isnull)
			ereport(ERROR,
					(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
					 errmsg("frame starting offset must not be null")));
		/* copy value into query-lifespan context */
		get_typlenbyval(exprType((Node *) winstate->startOffset->expr),
						&len,
						&byval);
		winstate->startOffsetValue = datumCopy(value, byval, len);
		if (frameOptions & (FRAMEOPTION_ROWS | FRAMEOPTION_GROUPS))
		{
			/* value is known to be int8 */
			int64		offset = DatumGetInt64(value);

			if (offset < 0)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PRECEDING_OR_FOLLOWING_SIZE),
						 errmsg("frame starting offset must not be negative")));
		}
	}

	if (frameOptions & FRAMEOPTION_END_OFFSET)
	{
		Assert(winstate->endOffset != NULL);
		value = ExecEvalExprSwitchContext(winstate->endOffset,
										  econtext,
										  &isnull);
		if (isnull)
			ereport(ERROR,
					(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
					 errmsg("frame ending offset must not be null")));
		/* copy value into query-lifespan context */
		get_typlenbyval(exprType((Node *) winstate->endOffset->expr),
						&len,
						&byval);
		winstate->endOffsetValue = datumCopy(value, byval, len);
		if (frameOptions & (FRAMEOPTION_ROWS | FRAMEOPTION_GROUPS))
		{
			/* value is known to be int8 */
			int64		offset = DatumGetInt64(value);

			if (offset < 0)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PRECEDING_OR_FOLLOWING_SIZE),
						 errmsg("frame ending offset must not be negative")));

			/*
			 * 행 패턴 인식은 길이가 0 인 프레임 끝을 금지한다. 이 검사는
			 * 여기서 이루어지므로 리터럴 0 뿐 아니라 (바인드 매개변수 같은)
			 * 상수가 아닌 오프셋도 걸러낸다.
			 */
			if (winstate->rpPattern != NULL && offset == 0)
				ereport(ERROR,
						errcode(ERRCODE_WINDOWING_ERROR),
						errmsg("frame ending offset must be positive with row pattern recognition"));
		}
	}
	winstate->all_first = false;
}

/* -----------------
 * ExecWindowAgg
 *
 *	ExecWindowAgg receives tuples from its outer subplan and
 *	stores them into a tuplestore, then processes window functions.
 *	This node doesn't reduce nor qualify any row so the number of
 *	returned rows is exactly the same as its outer subplan's result.
 * -----------------
 */
static TupleTableSlot *
ExecWindowAgg(PlanState *pstate)
{
	WindowAggState *winstate = castNode(WindowAggState, pstate);
	TupleTableSlot *slot;
	ExprContext *econtext;
	int			i;
	int			numfuncs;

	CHECK_FOR_INTERRUPTS();

	if (winstate->status == WINDOWAGG_DONE)
		return NULL;

	/*
	 * Compute frame offset values, if any, during first call (or after a
	 * rescan).  These are assumed to hold constant throughout the scan; if
	 * user gives us a volatile expression, we'll only use its initial value.
	 */
	if (unlikely(winstate->all_first))
		calculate_frame_offsets(pstate);

	/*
	 * 첫 호출 시(또는 rescan 후) 같은 방식으로 내비게이션 오프셋을 확정한다.
	 * 내비게이션을 가진 모든 RPR 윈도우는 이 지점을 거친다: 초기화 시점의
	 * 처리는 EXPLAIN 표시를 위해 상수 오프셋을 검증 없이 확정했으므로,
	 * null이나 음수 오프셋을 거부하는 곳은 바로 여기다.
	 */
	if (unlikely(winstate->navResolvePending))
		resolve_nav_offsets(winstate);

	/* We need to loop as the runCondition or qual may filter out tuples */
	for (;;)
	{
		if (winstate->next_partition)
		{
			/* Initialize for first partition and set current row = 0 */
			begin_partition(winstate);
			/* If there are no input rows, we'll detect that and exit below */
		}
		else
		{
			/* Advance current row within partition */
			winstate->currentpos++;
			/* This might mean that the frame moves, too */
			winstate->framehead_valid = false;
			winstate->frametail_valid = false;
			/* we don't need to invalidate grouptail here; see below */
		}

		/*
		 * Spool all tuples up to and including the current row, if we haven't
		 * already
		 */
		spool_tuples(winstate, winstate->currentpos);

		/* Move to the next partition if we reached the end of this partition */
		if (winstate->partition_spooled &&
			winstate->currentpos >= winstate->spooled_rows)
		{
			release_partition(winstate);

			if (winstate->more_partitions)
			{
				begin_partition(winstate);
				Assert(winstate->spooled_rows > 0);

				/* Come out of pass-through mode when changing partition */
				winstate->status = WINDOWAGG_RUN;
			}
			else
			{
				/* No further partitions?  We're done */
				winstate->status = WINDOWAGG_DONE;
				return NULL;
			}
		}

		/* final output execution is in ps_ExprContext */
		econtext = winstate->ss.ps.ps_ExprContext;

		/* Clear the per-output-tuple context for current row */
		ResetExprContext(econtext);

		/*
		 * Read the current row from the tuplestore, and save in
		 * ScanTupleSlot. (We can't rely on the outerplan's output slot
		 * because we may have to read beyond the current row.  Also, we have
		 * to actually copy the row out of the tuplestore, since window
		 * function evaluation might cause the tuplestore to dump its state to
		 * disk.)
		 *
		 * In GROUPS mode, or when tracking a group-oriented exclusion clause,
		 * we must also detect entering a new peer group and update associated
		 * state when that happens.  We use temp_slot_2 to temporarily hold
		 * the previous row for this purpose.
		 *
		 * Current row must be in the tuplestore, since we spooled it above.
		 */
		tuplestore_select_read_pointer(winstate->buffer, winstate->current_ptr);
		if ((winstate->frameOptions & (FRAMEOPTION_GROUPS |
									   FRAMEOPTION_EXCLUDE_GROUP |
									   FRAMEOPTION_EXCLUDE_TIES)) &&
			winstate->currentpos > 0)
		{
			ExecCopySlot(winstate->temp_slot_2, winstate->ss.ss_ScanTupleSlot);
			if (!tuplestore_gettupleslot(winstate->buffer, true, true,
										 winstate->ss.ss_ScanTupleSlot))
				elog(ERROR, "unexpected end of tuplestore");
			if (!are_peers(winstate, winstate->temp_slot_2,
						   winstate->ss.ss_ScanTupleSlot))
			{
				winstate->currentgroup++;
				winstate->groupheadpos = winstate->currentpos;
				winstate->grouptail_valid = false;
			}
			ExecClearTuple(winstate->temp_slot_2);
		}
		else
		{
			if (!tuplestore_gettupleslot(winstate->buffer, true, true,
										 winstate->ss.ss_ScanTupleSlot))
				elog(ERROR, "unexpected end of tuplestore");
		}

		/* don't evaluate the window functions when we're in pass-through mode */
		if (winstate->status == WINDOWAGG_RUN)
		{
			if (rpr_is_defined(winstate))
			{
				/*
				 * SKIP TO NEXT ROW 에서는 기록된 매치를 지워, 이 행이 자신의
				 * 시작점부터 다시 매치되도록 한다.
				 */
				if (winstate->rpSkipTo == ST_NEXT_ROW)
					clear_reduced_frame(winstate);

				/*
				 * 행 패턴 매치는 프레임 접근이 아니라 행 스캔을 따라가도록 매
				 * 행마다 구동한다.  (NULL 오프셋을 준 nth_value()처럼)
				 * 프레임을 건너뛰는 윈도우 함수라도 매치 상태를
				 * currentpos보다 뒤에 남겨두면 안 되기 때문이다.
				 */
				Assert(winstate->nav_winobj != NULL);
				ensure_reduced_frame(winstate->nav_winobj,
									 winstate->currentpos);
			}

			/*
			 * Evaluate true window functions
			 */
			numfuncs = winstate->numfuncs;
			for (i = 0; i < numfuncs; i++)
			{
				WindowStatePerFunc perfuncstate = &(winstate->perfunc[i]);

				if (perfuncstate->plain_agg)
					continue;
				eval_windowfunction(winstate, perfuncstate,
									&(econtext->ecxt_aggvalues[perfuncstate->wfuncstate->wfuncno]),
									&(econtext->ecxt_aggnulls[perfuncstate->wfuncstate->wfuncno]));
			}

			/*
			 * Evaluate aggregates
			 */
			if (winstate->numaggs > 0)
				eval_windowaggregates(winstate);
		}

		/*
		 * If we have created auxiliary read pointers for the frame or group
		 * boundaries, force them to be kept up-to-date, because we don't know
		 * whether the window function(s) will do anything that requires that.
		 * Failing to advance the pointers would result in being unable to
		 * trim data from the tuplestore, which is bad.  (If we could know in
		 * advance whether the window functions will use frame boundary info,
		 * we could skip creating these pointers in the first place ... but
		 * unfortunately the window function API doesn't require that.)
		 */
		if (winstate->framehead_ptr >= 0)
			update_frameheadpos(winstate);
		if (winstate->frametail_ptr >= 0)
			update_frametailpos(winstate);
		if (winstate->grouptail_ptr >= 0)
			update_grouptailpos(winstate);

		/*
		 * Truncate any no-longer-needed rows from the tuplestore.
		 */
		tuplestore_trim(winstate->buffer);

		/*
		 * Form and return a projection tuple using the windowfunc results and
		 * the current row.  Setting ecxt_outertuple arranges that any Vars
		 * will be evaluated with respect to that row.
		 */
		econtext->ecxt_outertuple = winstate->ss.ss_ScanTupleSlot;

		slot = ExecProject(winstate->ss.ps.ps_ProjInfo);

		if (winstate->status == WINDOWAGG_RUN)
		{
			econtext->ecxt_scantuple = slot;

			/*
			 * Now evaluate the run condition to see if we need to go into
			 * pass-through mode, or maybe stop completely.
			 */
			if (!ExecQual(winstate->runcondition, econtext))
			{
				/*
				 * Determine which mode to move into.  If there is no
				 * PARTITION BY clause and we're the top-level WindowAgg then
				 * we're done.  This tuple and any future tuples cannot
				 * possibly match the runcondition.  However, when there is a
				 * PARTITION BY clause or we're not the top-level window we
				 * can't just stop as we need to either process other
				 * partitions or ensure WindowAgg nodes above us receive all
				 * of the tuples they need to process their WindowFuncs.
				 */
				if (winstate->use_pass_through)
				{
					/*
					 * When switching into a pass-through mode, we'd better
					 * NULLify the aggregate results as these are no longer
					 * updated and NULLifying them avoids the old stale
					 * results lingering.  Some of these might be byref types
					 * so we can't have them pointing to free'd memory.  The
					 * planner insisted that quals used in the runcondition
					 * are strict, so the top-level WindowAgg will always
					 * filter these NULLs out in the filter clause.
					 */
					numfuncs = winstate->numfuncs;
					for (i = 0; i < numfuncs; i++)
					{
						econtext->ecxt_aggvalues[i] = (Datum) 0;
						econtext->ecxt_aggnulls[i] = true;
					}

					/*
					 * STRICT pass-through mode is required for the top window
					 * when there is a PARTITION BY clause.  Otherwise we must
					 * ensure we store tuples that don't match the
					 * runcondition so they're available to WindowAggs above.
					 */
					if (winstate->top_window)
					{
						winstate->status = WINDOWAGG_PASSTHROUGH_STRICT;
						continue;
					}
					else
					{
						winstate->status = WINDOWAGG_PASSTHROUGH;
					}
				}
				else
				{
					/*
					 * Pass-through not required.  We can just return NULL.
					 * Nothing else will match the runcondition.
					 */
					winstate->status = WINDOWAGG_DONE;
					return NULL;
				}
			}

			/*
			 * Filter out any tuples we don't need in the top-level WindowAgg.
			 */
			if (!ExecQual(winstate->ss.ps.qual, econtext))
			{
				InstrCountFiltered1(winstate, 1);
				continue;
			}

			break;
		}

		/*
		 * When not in WINDOWAGG_RUN mode, we must still return this tuple if
		 * we're anything apart from the top window.
		 */
		else if (!winstate->top_window)
			break;
	}

	return slot;
}

/* -----------------
 * ExecInitWindowAgg
 *
 *	Creates the run-time information for the WindowAgg node produced by the
 *	planner and initializes its outer subtree
 * -----------------
 */
WindowAggState *
ExecInitWindowAgg(WindowAgg *node, EState *estate, int eflags)
{
	WindowAggState *winstate;
	Plan	   *outerPlan;
	ExprContext *econtext;
	ExprContext *tmpcontext;
	WindowStatePerFunc perfunc;
	WindowStatePerAgg peragg;
	int			frameOptions = node->frameOptions;
	int			numfuncs,
				wfuncno,
				numaggs,
				aggno;
	TupleDesc	scanDesc;
	ListCell   *l;

	/* check for unsupported flags */
	Assert(!(eflags & (EXEC_FLAG_BACKWARD | EXEC_FLAG_MARK)));

	/*
	 * create state structure
	 */
	winstate = makeNode(WindowAggState);
	winstate->ss.ps.plan = (Plan *) node;
	winstate->ss.ps.state = estate;
	winstate->ss.ps.ExecProcNode = ExecWindowAgg;

	/* copy frame options to state node for easy access */
	winstate->frameOptions = frameOptions;

	/*
	 * Create expression contexts.  입력 튜플별 처리용과 출력 튜플별 처리용 두
	 * 개가 필요하고, 여기에 더해 행 패턴 인식 DEFINE 평가를 위한 선택적 세
	 * 번째 컨텍스트가 (DEFINE 절이 있을 때 바로 아래에서) 만들어진다.  이들
	 * 모두를 만드는 데 ExecAssignExprContext()를 약간 편법으로 사용하는데, 이
	 * 함수는 호출할 때마다 ps_ExprContext 를 덮어쓰므로 마지막 호출이 출력
	 * 컨텍스트를 설정하게 된다.
	 */
	ExecAssignExprContext(estate, &winstate->ss.ps);
	tmpcontext = winstate->ss.ps.ps_ExprContext;
	winstate->tmpcontext = tmpcontext;

	/*
	 * 행 패턴 인식은 DEFINE 절을 세 번째 컨텍스트에서 평가하며, 이 컨텍스트는
	 * 각 DEFINE 평가 패스 전에 재설정된다.  tmpcontext, ps_ExprContext 와는
	 * 구분되어야 하는데, 그래야 이 컨텍스트를 재설정해도 입력이나 출력 튜플
	 * 메모리가 해제되지 않는다.
	 */
	if (node->defineClause != NIL)
	{
		ExecAssignExprContext(estate, &winstate->ss.ps);
		winstate->rprContext = winstate->ss.ps.ps_ExprContext;
	}

	ExecAssignExprContext(estate, &winstate->ss.ps);

	/* Create long-lived context for storage of partition-local memory etc */
	winstate->partcontext =
		AllocSetContextCreate(CurrentMemoryContext,
							  "WindowAgg Partition",
							  ALLOCSET_DEFAULT_SIZES);

	/*
	 * Create mid-lived context for aggregate trans values etc.
	 *
	 * Note that moving aggregates each use their own private context, not
	 * this one.
	 */
	winstate->aggcontext =
		AllocSetContextCreate(CurrentMemoryContext,
							  "WindowAgg Aggregates",
							  ALLOCSET_DEFAULT_SIZES);

	/* Only the top-level WindowAgg may have a qual */
	Assert(node->plan.qual == NIL || node->topWindow);

	/* Initialize the qual */
	winstate->ss.ps.qual = ExecInitQual(node->plan.qual,
										(PlanState *) winstate);

	/*
	 * Setup the run condition, if we received one from the query planner.
	 * When set, this may allow us to move into pass-through mode so that we
	 * don't have to perform any further evaluation of WindowFuncs in the
	 * current partition or possibly stop returning tuples altogether when all
	 * tuples are in the same partition.
	 */
	winstate->runcondition = ExecInitQual(node->runCondition,
										  (PlanState *) winstate);

	/*
	 * When we're not the top-level WindowAgg node or we are but have a
	 * PARTITION BY clause we must move into one of the WINDOWAGG_PASSTHROUGH*
	 * modes when the runCondition becomes false.
	 */
	winstate->use_pass_through = !node->topWindow || node->partNumCols > 0;

	/* remember if we're the top-window or we are below the top-window */
	winstate->top_window = node->topWindow;

	/*
	 * initialize child nodes
	 */
	outerPlan = outerPlan(node);
	outerPlanState(winstate) = ExecInitNode(outerPlan, estate, eflags);

	/*
	 * initialize source tuple type (which is also the tuple type that we'll
	 * store in the tuplestore and use in all our working slots).
	 */
	ExecCreateScanSlotFromOuterPlan(estate, &winstate->ss, &TTSOpsMinimalTuple);
	scanDesc = winstate->ss.ss_ScanTupleSlot->tts_tupleDescriptor;

	/* the outer tuple isn't the child's tuple, but always a minimal tuple */
	winstate->ss.ps.outeropsset = true;
	winstate->ss.ps.outerops = &TTSOpsMinimalTuple;
	winstate->ss.ps.outeropsfixed = true;

	/*
	 * tuple table initialization
	 */
	winstate->first_part_slot = ExecInitExtraTupleSlot(estate, scanDesc,
													   &TTSOpsMinimalTuple);
	winstate->agg_row_slot = ExecInitExtraTupleSlot(estate, scanDesc,
													&TTSOpsMinimalTuple);
	winstate->temp_slot_1 = ExecInitExtraTupleSlot(estate, scanDesc,
												   &TTSOpsMinimalTuple);
	winstate->temp_slot_2 = ExecInitExtraTupleSlot(estate, scanDesc,
												   &TTSOpsMinimalTuple);

	/*
	 * create frame head and tail slots only if needed (must create slots in
	 * exactly the same cases that update_frameheadpos and update_frametailpos
	 * need them)
	 */
	winstate->framehead_slot = winstate->frametail_slot = NULL;

	if (frameOptions & (FRAMEOPTION_RANGE | FRAMEOPTION_GROUPS))
	{
		if (((frameOptions & FRAMEOPTION_START_CURRENT_ROW) &&
			 node->ordNumCols != 0) ||
			(frameOptions & FRAMEOPTION_START_OFFSET))
			winstate->framehead_slot = ExecInitExtraTupleSlot(estate, scanDesc,
															  &TTSOpsMinimalTuple);
		if (((frameOptions & FRAMEOPTION_END_CURRENT_ROW) &&
			 node->ordNumCols != 0) ||
			(frameOptions & FRAMEOPTION_END_OFFSET))
			winstate->frametail_slot = ExecInitExtraTupleSlot(estate, scanDesc,
															  &TTSOpsMinimalTuple);
	}

	/*
	 * Initialize result slot, type and projection.
	 */
	ExecInitResultTupleSlotTL(&winstate->ss.ps, &TTSOpsVirtual);
	ExecAssignProjectionInfo(&winstate->ss.ps, NULL);

	/* Set up data for comparing tuples */
	if (node->partNumCols > 0)
		winstate->partEqfunction =
			execTuplesMatchPrepare(scanDesc,
								   node->partNumCols,
								   node->partColIdx,
								   node->partOperators,
								   node->partCollations,
								   &winstate->ss.ps);

	if (node->ordNumCols > 0)
		winstate->ordEqfunction =
			execTuplesMatchPrepare(scanDesc,
								   node->ordNumCols,
								   node->ordColIdx,
								   node->ordOperators,
								   node->ordCollations,
								   &winstate->ss.ps);

	/*
	 * WindowAgg nodes use aggvalues and aggnulls as well as Agg nodes.
	 */
	numfuncs = winstate->numfuncs;
	numaggs = winstate->numaggs;
	econtext = winstate->ss.ps.ps_ExprContext;
	econtext->ecxt_aggvalues = palloc0_array(Datum, numfuncs);
	econtext->ecxt_aggnulls = palloc0_array(bool, numfuncs);

	/*
	 * allocate per-wfunc/per-agg state information.
	 */
	perfunc = palloc0_array(WindowStatePerFuncData, numfuncs);
	peragg = palloc0_array(WindowStatePerAggData, numaggs);
	winstate->perfunc = perfunc;
	winstate->peragg = peragg;

	wfuncno = -1;
	aggno = -1;
	foreach(l, winstate->funcs)
	{
		WindowFuncExprState *wfuncstate = (WindowFuncExprState *) lfirst(l);
		WindowFunc *wfunc = wfuncstate->wfunc;
		WindowStatePerFunc perfuncstate;
		AclResult	aclresult;
		int			i;

		if (wfunc->winref != node->winref)	/* planner screwed up? */
			elog(ERROR, "WindowFunc with winref %u assigned to WindowAgg with winref %u",
				 wfunc->winref, node->winref);

		/* Look for a previous duplicate window function */
		for (i = 0; i <= wfuncno; i++)
		{
			if (equal(wfunc, perfunc[i].wfunc) &&
				!contain_volatile_functions((Node *) wfunc))
				break;
		}
		if (i <= wfuncno)
		{
			/* Found a match to an existing entry, so just mark it */
			wfuncstate->wfuncno = i;
			continue;
		}

		/* Nope, so assign a new PerAgg record */
		perfuncstate = &perfunc[++wfuncno];

		/* Mark WindowFunc state node with assigned index in the result array */
		wfuncstate->wfuncno = wfuncno;

		/* Check permission to call window function */
		aclresult = object_aclcheck(ProcedureRelationId, wfunc->winfnoid, GetUserId(),
									ACL_EXECUTE);
		if (aclresult != ACLCHECK_OK)
			aclcheck_error(aclresult, OBJECT_FUNCTION,
						   get_func_name(wfunc->winfnoid));
		InvokeFunctionExecuteHook(wfunc->winfnoid);

		/* Fill in the perfuncstate data */
		perfuncstate->wfuncstate = wfuncstate;
		perfuncstate->wfunc = wfunc;
		perfuncstate->numArguments = list_length(wfuncstate->args);
		perfuncstate->winCollation = wfunc->inputcollid;

		get_typlenbyval(wfunc->wintype,
						&perfuncstate->resulttypeLen,
						&perfuncstate->resulttypeByVal);

		/*
		 * If it's really just a plain aggregate function, we'll emulate the
		 * Agg environment for it.
		 */
		perfuncstate->plain_agg = wfunc->winagg;
		if (wfunc->winagg)
		{
			WindowStatePerAgg peraggstate;

			perfuncstate->aggno = ++aggno;
			peraggstate = &winstate->peragg[aggno];
			initialize_peragg(winstate, wfunc, peraggstate);
			peraggstate->wfuncno = wfuncno;
		}
		else
		{
			WindowObject winobj = makeNode(WindowObjectData);

			winobj->winstate = winstate;
			winobj->argstates = wfuncstate->args;
			winobj->localmem = NULL;
			perfuncstate->winobj = winobj;
			winobj->ignore_nulls = wfunc->ignore_nulls;
			init_notnull_info(winobj, perfuncstate);

			/* It's a real window function, so set up to call it. */
			fmgr_info_cxt(wfunc->winfnoid, &perfuncstate->flinfo,
						  econtext->ecxt_per_query_memory);
			fmgr_info_set_expr((Node *) wfunc, &perfuncstate->flinfo);
		}
	}

	/* Update numfuncs, numaggs to match number of unique functions found */
	winstate->numfuncs = wfuncno + 1;
	winstate->numaggs = aggno + 1;

	/* Set up WindowObject for aggregates, if needed */
	if (winstate->numaggs > 0)
	{
		WindowObject agg_winobj = makeNode(WindowObjectData);

		agg_winobj->winstate = winstate;
		agg_winobj->argstates = NIL;
		agg_winobj->localmem = NULL;
		/* make sure markptr = -1 to invalidate. It may not get used */
		agg_winobj->markptr = -1;
		agg_winobj->readptr = -1;
		winstate->agg_winobj = agg_winobj;
	}

	/* Set the status to running */
	winstate->status = WINDOWAGG_RUN;

	/* initialize frame bound offset expressions */
	winstate->startOffset = ExecInitExpr((Expr *) node->startOffset,
										 (PlanState *) winstate);
	winstate->endOffset = ExecInitExpr((Expr *) node->endOffset,
									   (PlanState *) winstate);

	/* Lookup in_range support functions if needed */
	if (OidIsValid(node->startInRangeFunc))
		fmgr_info(node->startInRangeFunc, &winstate->startInRangeFunc);
	if (OidIsValid(node->endInRangeFunc))
		fmgr_info(node->endInRangeFunc, &winstate->endInRangeFunc);
	winstate->inRangeColl = node->inRangeColl;
	winstate->inRangeAsc = node->inRangeAsc;
	winstate->inRangeNullsFirst = node->inRangeNullsFirst;

	winstate->all_first = true;
	winstate->partition_spooled = false;
	winstate->more_partitions = false;
	winstate->next_partition = true;

	/*
	 * RPR 관련 항목을, nav 오프셋을 제외하면 구조체 선언 순서대로 채운다.
	 * nav 오프셋은 아래의 build_define_offsets()가 누적해 채운다.  네 개의
	 * NFALengthStats 멤버는 palloc0이 준 0 값을 그대로 유지한다.
	 */
	if (node->rpPattern != NULL)
	{
		int			nfaVisitedNWords;
		WindowObject nav_winobj;

		winstate->rpSkipTo = node->rpSkipTo;
		winstate->rpPattern = node->rpPattern;
		winstate->defineClauseExprs = NIL;

		winstate->rprNavOffsets = NIL;
		winstate->navMaxOffset = 0;
		winstate->navMaxOffsetKind = RPR_NAV_OFFSET_FIXED;
		winstate->hasMaxNav = false;
		winstate->hasFirstNav = false;
		winstate->navFirstOffset = 0;
		winstate->navFirstOffsetKind = RPR_NAV_OFFSET_FIXED;

		/*
		 * defineClause 에 대한 ExecInitQual() 루프보다 먼저 이 함수를 실행해야
		 * 한다.  각 RPRNavExpr 을 컴파일하는 동안 ExecInitQual()이
		 * winstate->rprNavOffsets 를 읽어 RPRNavState 를 해당 항목과 연결하고
		 * 오프셋을 채우는데, 이 호출이 바로 그 목록을 채우는 부분이기 때문이다
		 */
		build_define_offsets(winstate, node->defineClause);

		/*
		 * DEFINE 절 표현식을 컴파일한다.  PREV/NEXT 내비게이션은 ExecInitQual
		 * 도중 방출되는 EEOP_RPR_NAV_SET/RESTORE opcode가 처리하므로,
		 * 여기서는 varno 재작성이 필요 없다.  표현식은 DEFINE 순서로
		 * 유지되므로, 리스트 인덱스가 곧 그 변수의 varId 와 같다.
		 */
		foreach_node(TargetEntry, te, node->defineClause)
		{
			ExprState  *exprstate;

			/*
			 * 그 인덱스는 buildRPRPattern()에서 확립되고 여기서 소비되며, 그
			 * 사이에는 이를 검사하는 곳이 없다.  오늘은 이 리스트를 다루는
			 * 모든 단계가 순서를 보존하지만, 순서가 뒤바뀌면 한 변수의 검색
			 * 조건을 다른 변수에 대해 평가하면서도 아무 표시 없이 잘못된 답을
			 * 낼 것이다.  그래서 패턴이 이 위치에 대해 들고 있는 이름을 항목
			 * 자신의 이름과 대조해 확인한다.
			 */
			Assert(foreach_current_index(te) < node->rpPattern->numVars);
			Assert(strcmp(node->rpPattern->varNames[foreach_current_index(te)],
						  te->resname) == 0);

			exprstate = ExecInitQual(make_ands_implicit(te->expr), (PlanState *) winstate);

			winstate->defineClauseExprs =
				lappend(winstate->defineClauseExprs, exprstate);
		}

		/* 행 패턴 매칭을 위한 NFA free list를 초기화한다 */
		winstate->nfaContext = NULL;
		winstate->nfaContextTail = NULL;
		winstate->nfaContextFree = NULL;
		winstate->nfaStateFree = NULL;
		winstate->nfaStateSize = offsetof(RPRNFAState, counts) +
			sizeof(int32) * node->rpPattern->maxDepth;

		/*
		 * 행별 varMatched 캐시를 할당한다.  varNames 는 DEFINE 순서로
		 * 만들어지므로 varId 가 곧 DEFINE 리스트 인덱스이며 별도의 매핑이
		 * 필요 없다.
		 *
		 * 문법상 행 패턴 윈도우에는 DEFINE 이 반드시 있어야 하고, 이 분기는
		 * 그런 경우에만 실행되므로 리스트가 비어 있는 일은 없으며
		 * rpr_prepare_row()는 무조건 캐시를 재설정할 수 있다.
		 */
		Assert(winstate->defineClauseExprs != NIL);
		winstate->nfaVarMatched = palloc0(sizeof(RPRVarMatch) *
										  list_length(winstate->defineClauseExprs));

		/* 컨텍스트별 평가를 위해 match_start 의존성 bitmapset을 복사한다 */
		winstate->defineMatchStartDependent = bms_copy(node->defineMatchStartDependent);

		nfaVisitedNWords =
			(node->rpPattern->numElements - 1) / BITS_PER_BITMAPWORD + 1;

		winstate->nfaVisitedEnds = palloc0(sizeof(bitmapword) *
										   nfaVisitedNWords);

		/* 최고 수위 sentinel: 아직 설정된 비트가 없다. */
		winstate->nfaVisitedMinWord = PG_INT16_MAX;
		winstate->nfaVisitedMaxWord = -1;

		winstate->nfaLastProcessedRow = -1;
		winstate->nfaStatesActive = 0;
		winstate->nfaStatesMax = 0;
		winstate->nfaStatesTotalCreated = 0;
		winstate->nfaStatesMerged = 0;
		winstate->nfaContextsActive = 0;
		winstate->nfaContextsMax = 0;
		winstate->nfaContextsTotalCreated = 0;
		winstate->nfaContextsAbsorbed = 0;
		winstate->nfaContextsSkipped = 0;
		winstate->nfaContextsPruned = 0;
		winstate->nfaMatchesSucceeded = 0;
		winstate->nfaMatchesFailed = 0;

		/*
		 * nav 오프셋은 프레임 오프셋과 마찬가지로 실행 시점에
		 * (그리고 검증되어) 확정된다: 모든 RPR 윈도우에 대해 첫 스캔과 매
		 * rescan 이후에 확정한다.
		 */
		winstate->navResolvePending = (winstate->rprNavOffsets != NIL);

		/*
		 * RPR 내비게이션 opcode를 위한 WindowObject 를 준비한다.  집계 처리를
		 * 방해하지 않도록 자신만의 read 포인터가 필요하므로 agg_winobj 와는
		 * 별도로 둔다.
		 */
		nav_winobj = makeNode(WindowObjectData);
		nav_winobj->winstate = winstate;
		nav_winobj->argstates = NIL;
		nav_winobj->localmem = NULL;
		nav_winobj->markptr = -1;
		nav_winobj->readptr = -1;
		winstate->nav_winobj = nav_winobj;

		winstate->nav_slot_pos = -1;
		winstate->nav_slot = ExecInitExtraTupleSlot(estate, scanDesc,
													&TTSOpsMinimalTuple);
		winstate->nav_saved_outertuple = NULL;
		winstate->nav_match_start = 0;
		winstate->rpr_match_start = -1;
		winstate->rpr_match_length = -1;
	}

	return winstate;
}

/*
 * ExecRPRNavGetSlot
 *
 * RPR 내비게이션 opcode를 위해 주어진 위치의 튜플을 가져온다. 튜플이 채워진
 * nav_slot 을 반환하거나, 범위를 벗어나면 NULL 을 반환한다.
 */
TupleTableSlot *
ExecRPRNavGetSlot(WindowAggState *winstate, int64 pos)
{
	WindowObject winobj = winstate->nav_winobj;
	TupleTableSlot *slot = winstate->nav_slot;

	if (pos < 0)
		return NULL;

	/*
	 * nav_slot 이 이미 이 위치를 담고 있다면 다시 가져오지 않고 그대로
	 * 반환한다.  같은 표현식 안의 여러 내비게이션이 같은 행을 대상으로 할 때
	 * tuplestore 조회를 절약해 준다.  앞서 나온 pass-by-ref 결과는 여기에
	 * 의존하지 않는다: EEOP_RPR_NAV_RESTORE 가 nav_slot 의 튜플 메모리에서 그
	 * 값을 복사해 내기 때문이다.
	 */
	if (winstate->nav_slot_pos == pos)
		return slot;

	if (!window_gettupleslot(winobj, pos, slot))
	{
		winstate->nav_slot_pos = -1;
		return NULL;
	}

	winstate->nav_slot_pos = pos;
	return slot;
}


/* -----------------
 * ExecEndWindowAgg
 * -----------------
 */
void
ExecEndWindowAgg(WindowAggState *node)
{
	PlanState  *outerPlan;
	int			i;

	if (node->buffer != NULL)
	{
		tuplestore_end(node->buffer);

		/* nullify so that release_partition skips the tuplestore_clear() */
		node->buffer = NULL;
	}

	release_partition(node);

	for (i = 0; i < node->numaggs; i++)
	{
		if (node->peragg[i].aggcontext != node->aggcontext)
			MemoryContextDelete(node->peragg[i].aggcontext);
	}
	MemoryContextDelete(node->partcontext);
	MemoryContextDelete(node->aggcontext);

	pfree(node->perfunc);
	pfree(node->peragg);

	outerPlan = outerPlanState(node);
	ExecEndNode(outerPlan);
}

/* -----------------
 * ExecReScanWindowAgg
 * -----------------
 */
void
ExecReScanWindowAgg(WindowAggState *node)
{
	PlanState  *outerPlan = outerPlanState(node);
	ExprContext *econtext = node->ss.ps.ps_ExprContext;

	node->status = WINDOWAGG_RUN;
	node->all_first = true;
	/* 오프셋은 다음 스캔에서 다시 확정되고 다시 검증된다 */
	node->navResolvePending = (node->rprNavOffsets != NIL);

	/* release tuplestore et al */
	release_partition(node);

	/* release all temp tuples, but especially first_part_slot */
	ExecClearTuple(node->ss.ss_ScanTupleSlot);
	ExecClearTuple(node->first_part_slot);
	ExecClearTuple(node->agg_row_slot);
	ExecClearTuple(node->temp_slot_1);
	ExecClearTuple(node->temp_slot_2);
	if (node->nav_slot)
		ExecClearTuple(node->nav_slot);
	if (node->framehead_slot)
		ExecClearTuple(node->framehead_slot);
	if (node->frametail_slot)
		ExecClearTuple(node->frametail_slot);

	/* Forget current wfunc values */
	MemSet(econtext->ecxt_aggvalues, 0, sizeof(Datum) * node->numfuncs);
	MemSet(econtext->ecxt_aggnulls, 0, sizeof(bool) * node->numfuncs);

	/*
	 * if chgParam of subnode is not null then plan will be re-scanned by
	 * first ExecProcNode.
	 */
	if (outerPlan->chgParam == NULL)
		ExecReScan(outerPlan);
}

/*
 * initialize_peragg
 *
 * Almost same as in nodeAgg.c, except we don't support DISTINCT currently.
 */
static WindowStatePerAggData *
initialize_peragg(WindowAggState *winstate, WindowFunc *wfunc,
				  WindowStatePerAgg peraggstate)
{
	Oid			inputTypes[FUNC_MAX_ARGS];
	int			numArguments;
	HeapTuple	aggTuple;
	Form_pg_aggregate aggform;
	Oid			aggtranstype;
	AttrNumber	initvalAttNo;
	AclResult	aclresult;
	bool		use_ma_code;
	Oid			transfn_oid,
				invtransfn_oid,
				finalfn_oid;
	bool		finalextra;
	char		finalmodify;
	Expr	   *transfnexpr,
			   *invtransfnexpr,
			   *finalfnexpr;
	Datum		textInitVal;
	int			i;
	ListCell   *lc;

	numArguments = list_length(wfunc->args);

	/*
	 * Check the number of arguments, to protect fixed-size arrays here and
	 * later in node execution.
	 *
	 * Aggregates can have at most FUNC_MAX_ARGS-1 args (compare
	 * AggregateCreate, whose error message we want to match).  Ordinarily
	 * this would have been checked while creating the WindowFunc, but it's
	 * possible that we are looking at a parsetree from a stored view that was
	 * made by a server executable with a different value of FUNC_MAX_ARGS, or
	 * an executable in which parse_func.c didn't enforce the correct limit.
	 */
	if (numArguments > FUNC_MAX_ARGS - 1)
		ereport(ERROR,
				(errcode(ERRCODE_TOO_MANY_ARGUMENTS),
				 errmsg_plural("aggregates cannot have more than %d argument",
							   "aggregates cannot have more than %d arguments",
							   FUNC_MAX_ARGS - 1,
							   FUNC_MAX_ARGS - 1)));

	i = 0;
	foreach(lc, wfunc->args)
	{
		inputTypes[i++] = exprType((Node *) lfirst(lc));
	}

	aggTuple = SearchSysCache1(AGGFNOID, ObjectIdGetDatum(wfunc->winfnoid));
	if (!HeapTupleIsValid(aggTuple))
		elog(ERROR, "cache lookup failed for aggregate %u",
			 wfunc->winfnoid);
	aggform = (Form_pg_aggregate) GETSTRUCT(aggTuple);

	/*
	 * Figure out whether we want to use the moving-aggregate implementation,
	 * and collect the right set of fields from the pg_aggregate entry.
	 *
	 * It's possible that an aggregate would supply a safe moving-aggregate
	 * implementation and an unsafe normal one, in which case our hand is
	 * forced.  Otherwise, if the frame head can't move, we don't need
	 * moving-aggregate code.  Even if we'd like to use it, don't do so if the
	 * aggregate's arguments (and FILTER clause if any) contain any calls to
	 * volatile functions.  Otherwise, the difference between restarting and
	 * not restarting the aggregation would be user-visible.
	 *
	 * We also don't risk using moving aggregates when there are subplans in
	 * the arguments or FILTER clause.  This is partly because
	 * contain_volatile_functions() doesn't look inside subplans; but there
	 * are other reasons why a subplan's output might be volatile.  For
	 * example, syncscan mode can render the results nonrepeatable.
	 */
	if (!OidIsValid(aggform->aggminvtransfn))
		use_ma_code = false;	/* sine qua non */
	else if (aggform->aggmfinalmodify == AGGMODIFY_READ_ONLY &&
			 aggform->aggfinalmodify != AGGMODIFY_READ_ONLY)
		use_ma_code = true;		/* decision forced by safety */
	else if (winstate->frameOptions & FRAMEOPTION_START_UNBOUNDED_PRECEDING)
		use_ma_code = false;	/* non-moving frame head */
	else if (contain_volatile_functions((Node *) wfunc))
		use_ma_code = false;	/* avoid possible behavioral change */
	else if (contain_subplans((Node *) wfunc))
		use_ma_code = false;	/* subplans might contain volatile functions */
	else
		use_ma_code = true;		/* yes, let's use it */
	if (use_ma_code)
	{
		peraggstate->transfn_oid = transfn_oid = aggform->aggmtransfn;
		peraggstate->invtransfn_oid = invtransfn_oid = aggform->aggminvtransfn;
		peraggstate->finalfn_oid = finalfn_oid = aggform->aggmfinalfn;
		finalextra = aggform->aggmfinalextra;
		finalmodify = aggform->aggmfinalmodify;
		aggtranstype = aggform->aggmtranstype;
		initvalAttNo = Anum_pg_aggregate_aggminitval;
	}
	else
	{
		peraggstate->transfn_oid = transfn_oid = aggform->aggtransfn;
		peraggstate->invtransfn_oid = invtransfn_oid = InvalidOid;
		peraggstate->finalfn_oid = finalfn_oid = aggform->aggfinalfn;
		finalextra = aggform->aggfinalextra;
		finalmodify = aggform->aggfinalmodify;
		aggtranstype = aggform->aggtranstype;
		initvalAttNo = Anum_pg_aggregate_agginitval;
	}

	/*
	 * ExecInitWindowAgg already checked permission to call aggregate function
	 * ... but we still need to check the component functions
	 */

	/* Check that aggregate owner has permission to call component fns */
	{
		HeapTuple	procTuple;
		Oid			aggOwner;

		procTuple = SearchSysCache1(PROCOID,
									ObjectIdGetDatum(wfunc->winfnoid));
		if (!HeapTupleIsValid(procTuple))
			elog(ERROR, "cache lookup failed for function %u",
				 wfunc->winfnoid);
		aggOwner = ((Form_pg_proc) GETSTRUCT(procTuple))->proowner;
		ReleaseSysCache(procTuple);

		aclresult = object_aclcheck(ProcedureRelationId, transfn_oid, aggOwner,
									ACL_EXECUTE);
		if (aclresult != ACLCHECK_OK)
			aclcheck_error(aclresult, OBJECT_FUNCTION,
						   get_func_name(transfn_oid));
		InvokeFunctionExecuteHook(transfn_oid);

		if (OidIsValid(invtransfn_oid))
		{
			aclresult = object_aclcheck(ProcedureRelationId, invtransfn_oid, aggOwner,
										ACL_EXECUTE);
			if (aclresult != ACLCHECK_OK)
				aclcheck_error(aclresult, OBJECT_FUNCTION,
							   get_func_name(invtransfn_oid));
			InvokeFunctionExecuteHook(invtransfn_oid);
		}

		if (OidIsValid(finalfn_oid))
		{
			aclresult = object_aclcheck(ProcedureRelationId, finalfn_oid, aggOwner,
										ACL_EXECUTE);
			if (aclresult != ACLCHECK_OK)
				aclcheck_error(aclresult, OBJECT_FUNCTION,
							   get_func_name(finalfn_oid));
			InvokeFunctionExecuteHook(finalfn_oid);
		}
	}

	/*
	 * If the selected finalfn isn't read-only, we can't run this aggregate as
	 * a window function.  This is a user-facing error, so we take a bit more
	 * care with the error message than elsewhere in this function.
	 */
	if (finalmodify != AGGMODIFY_READ_ONLY)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("aggregate function %s does not support use as a window function",
						format_procedure(wfunc->winfnoid))));

	/* Detect how many arguments to pass to the finalfn */
	if (finalextra)
		peraggstate->numFinalArgs = numArguments + 1;
	else
		peraggstate->numFinalArgs = 1;

	/* resolve actual type of transition state, if polymorphic */
	aggtranstype = resolve_aggregate_transtype(wfunc->winfnoid,
											   aggtranstype,
											   inputTypes,
											   numArguments);

	/* build expression trees using actual argument & result types */
	build_aggregate_transfn_expr(inputTypes,
								 numArguments,
								 0, /* no ordered-set window functions yet */
								 false, /* no variadic window functions yet */
								 aggtranstype,
								 wfunc->inputcollid,
								 transfn_oid,
								 invtransfn_oid,
								 &transfnexpr,
								 &invtransfnexpr);

	/* set up infrastructure for calling the transfn(s) and finalfn */
	fmgr_info(transfn_oid, &peraggstate->transfn);
	fmgr_info_set_expr((Node *) transfnexpr, &peraggstate->transfn);

	if (OidIsValid(invtransfn_oid))
	{
		fmgr_info(invtransfn_oid, &peraggstate->invtransfn);
		fmgr_info_set_expr((Node *) invtransfnexpr, &peraggstate->invtransfn);
	}

	if (OidIsValid(finalfn_oid))
	{
		build_aggregate_finalfn_expr(inputTypes,
									 peraggstate->numFinalArgs,
									 aggtranstype,
									 wfunc->wintype,
									 wfunc->inputcollid,
									 finalfn_oid,
									 &finalfnexpr);
		fmgr_info(finalfn_oid, &peraggstate->finalfn);
		fmgr_info_set_expr((Node *) finalfnexpr, &peraggstate->finalfn);
	}

	/* get info about relevant datatypes */
	get_typlenbyval(wfunc->wintype,
					&peraggstate->resulttypeLen,
					&peraggstate->resulttypeByVal);
	get_typlenbyval(aggtranstype,
					&peraggstate->transtypeLen,
					&peraggstate->transtypeByVal);

	/*
	 * initval is potentially null, so don't try to access it as a struct
	 * field. Must do it the hard way with SysCacheGetAttr.
	 */
	textInitVal = SysCacheGetAttr(AGGFNOID, aggTuple, initvalAttNo,
								  &peraggstate->initValueIsNull);

	if (peraggstate->initValueIsNull)
		peraggstate->initValue = (Datum) 0;
	else
		peraggstate->initValue = GetAggInitVal(textInitVal,
											   aggtranstype);

	/*
	 * If the transfn is strict and the initval is NULL, make sure input type
	 * and transtype are the same (or at least binary-compatible), so that
	 * it's OK to use the first input value as the initial transValue.  This
	 * should have been checked at agg definition time, but we must check
	 * again in case the transfn's strictness property has been changed.
	 */
	if (peraggstate->transfn.fn_strict && peraggstate->initValueIsNull)
	{
		if (numArguments < 1 ||
			!IsBinaryCoercible(inputTypes[0], aggtranstype))
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
					 errmsg("aggregate %u needs to have compatible input type and transition type",
							wfunc->winfnoid)));
	}

	/*
	 * Insist that forward and inverse transition functions have the same
	 * strictness setting.  Allowing them to differ would require handling
	 * more special cases in advance_windowaggregate and
	 * advance_windowaggregate_base, for no discernible benefit.  This should
	 * have been checked at agg definition time, but we must check again in
	 * case either function's strictness property has been changed.
	 */
	if (OidIsValid(invtransfn_oid) &&
		peraggstate->transfn.fn_strict != peraggstate->invtransfn.fn_strict)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
				 errmsg("strictness of aggregate's forward and inverse transition functions must match")));

	/*
	 * Moving aggregates use their own aggcontext.
	 *
	 * This is necessary because they might restart at different times, so we
	 * might never be able to reset the shared context otherwise.  We can't
	 * make it the aggregates' responsibility to clean up after themselves,
	 * because strict aggregates must be restarted whenever we remove their
	 * last non-NULL input, which the aggregate won't be aware is happening.
	 * Also, just pfree()ing the transValue upon restarting wouldn't help,
	 * since we'd miss any indirectly referenced data.  We could, in theory,
	 * make the memory allocation rules for moving aggregates different than
	 * they have historically been for plain aggregates, but that seems grotty
	 * and likely to lead to memory leaks.
	 */
	if (OidIsValid(invtransfn_oid))
		peraggstate->aggcontext =
			AllocSetContextCreate(CurrentMemoryContext,
								  "WindowAgg Per Aggregate",
								  ALLOCSET_DEFAULT_SIZES);
	else
		peraggstate->aggcontext = winstate->aggcontext;

	ReleaseSysCache(aggTuple);

	return peraggstate;
}

static Datum
GetAggInitVal(Datum textInitVal, Oid transtype)
{
	Oid			typinput,
				typioparam;
	char	   *strInitVal;
	Datum		initVal;

	getTypeInputInfo(transtype, &typinput, &typioparam);
	strInitVal = TextDatumGetCString(textInitVal);
	initVal = OidInputFunctionCall(typinput, strInitVal,
								   typioparam, -1);
	pfree(strInitVal);
	return initVal;
}

/*
 * are_peers
 * compare two rows to see if they are equal according to the ORDER BY clause
 *
 * NB: this does not consider the window frame mode.
 */
static bool
are_peers(WindowAggState *winstate, TupleTableSlot *slot1,
		  TupleTableSlot *slot2)
{
	WindowAgg  *node = (WindowAgg *) winstate->ss.ps.plan;
	ExprContext *econtext = winstate->tmpcontext;

	/* If no ORDER BY, all rows are peers with each other */
	if (node->ordNumCols == 0)
		return true;

	econtext->ecxt_outertuple = slot1;
	econtext->ecxt_innertuple = slot2;
	return ExecQualAndReset(winstate->ordEqfunction, econtext);
}

/*
 * window_gettupleslot
 *	Fetch the pos'th tuple of the current partition into the slot,
 *	using the winobj's read pointer
 *
 * Returns true if successful, false if no such row
 */
static bool
window_gettupleslot(WindowObject winobj, int64 pos, TupleTableSlot *slot)
{
	WindowAggState *winstate = winobj->winstate;
	MemoryContext oldcontext;

	/* often called repeatedly in a row */
	CHECK_FOR_INTERRUPTS();

	/* Don't allow passing -1 to spool_tuples here */
	if (pos < 0)
		return false;

	/* If necessary, fetch the tuple into the spool */
	spool_tuples(winstate, pos);

	if (pos >= winstate->spooled_rows)
		return false;

	if (pos < winobj->markpos)
		elog(ERROR, "cannot fetch row before WindowObject's mark position");

	oldcontext = MemoryContextSwitchTo(winstate->ss.ps.ps_ExprContext->ecxt_per_query_memory);

	tuplestore_select_read_pointer(winstate->buffer, winobj->readptr);

	/*
	 * Advance or rewind until we are within one tuple of the one we want.
	 */
	if (winobj->seekpos < pos - 1)
	{
		if (!tuplestore_skiptuples(winstate->buffer,
								   pos - 1 - winobj->seekpos,
								   true))
			elog(ERROR, "unexpected end of tuplestore");
		winobj->seekpos = pos - 1;
	}
	else if (winobj->seekpos > pos + 1)
	{
		if (!tuplestore_skiptuples(winstate->buffer,
								   winobj->seekpos - (pos + 1),
								   false))
			elog(ERROR, "unexpected end of tuplestore");
		winobj->seekpos = pos + 1;
	}
	else if (winobj->seekpos == pos)
	{
		/*
		 * There's no API to refetch the tuple at the current position.  We
		 * have to move one tuple forward, and then one backward.  (We don't
		 * do it the other way because we might try to fetch the row before
		 * our mark, which isn't allowed.)  XXX this case could stand to be
		 * optimized.
		 */
		tuplestore_advance(winstate->buffer, true);
		winobj->seekpos++;
	}

	/*
	 * Now we should be on the tuple immediately before or after the one we
	 * want, so just fetch forwards or backwards as appropriate.
	 *
	 * Notice that we tell tuplestore_gettupleslot to make a physical copy of
	 * the fetched tuple.  This ensures that the slot's contents remain valid
	 * through manipulations of the tuplestore, which some callers depend on.
	 */
	if (winobj->seekpos > pos)
	{
		if (!tuplestore_gettupleslot(winstate->buffer, false, true, slot))
			elog(ERROR, "unexpected end of tuplestore");
		winobj->seekpos--;
	}
	else
	{
		if (!tuplestore_gettupleslot(winstate->buffer, true, true, slot))
			elog(ERROR, "unexpected end of tuplestore");
		winobj->seekpos++;
	}

	Assert(winobj->seekpos == pos);

	MemoryContextSwitchTo(oldcontext);

	return true;
}

/*
 * gettuple_eval_partition
 * get tuple in a partition and evaluate the window function's argument
 * expression on it.
 */
static Datum
gettuple_eval_partition(WindowObject winobj, int argno,
						int64 abs_pos, bool *isnull, bool *isout)
{
	WindowAggState *winstate;
	ExprContext *econtext;
	TupleTableSlot *slot;

	winstate = winobj->winstate;
	slot = winstate->temp_slot_1;
	if (!window_gettupleslot(winobj, abs_pos, slot))
	{
		/* out of partition */
		if (isout)
			*isout = true;
		*isnull = true;
		return (Datum) 0;
	}

	if (isout)
		*isout = false;
	econtext = winstate->ss.ps.ps_ExprContext;
	econtext->ecxt_outertuple = slot;
	return ExecEvalExpr((ExprState *) list_nth
						(winobj->argstates, argno),
						econtext, isnull);
}

/*
 * ignorenulls_getfuncarginframe
 * For IGNORE NULLS, get the next nonnull value in the frame, moving forward
 * or backward until we find a value or reach the frame's end.
 */
static Datum
ignorenulls_getfuncarginframe(WindowObject winobj, int argno,
							  int relpos, int seektype, bool set_mark,
							  bool *isnull, bool *isout)
{
	WindowAggState *winstate;
	ExprContext *econtext;
	TupleTableSlot *slot;
	Datum		datum;
	int64		abs_pos;
	int64		mark_pos;
	int			notnull_offset;
	int			notnull_relpos;
	int			forward;
	int64		num_reduced_frame;

	Assert(WindowObjectIsValid(winobj));
	winstate = winobj->winstate;
	econtext = winstate->ss.ps.ps_ExprContext;
	slot = winstate->temp_slot_1;
	datum = (Datum) 0;
	notnull_offset = 0;
	notnull_relpos = abs(relpos);

	switch (seektype)
	{
		case WINDOW_SEEK_CURRENT:
			elog(ERROR, "WINDOW_SEEK_CURRENT is not supported for WinGetFuncArgInFrame");
			abs_pos = mark_pos = 0; /* keep compiler quiet */
			break;
		case WINDOW_SEEK_HEAD:
			/* rejecting relpos < 0 is easy and simplifies code below */
			if (relpos < 0)
				goto out_of_frame;
			update_frameheadpos(winstate);
			abs_pos = winstate->frameheadpos;
			mark_pos = winstate->frameheadpos;
			forward = 1;
			break;
		case WINDOW_SEEK_TAIL:
			/* rejecting relpos > 0 is easy and simplifies code below */
			if (relpos > 0)
				goto out_of_frame;

			/*
			 * RPR 은 프레임 head 위치에 신경 쓴다.  update_frameheadpos 를
			 * 호출해야 한다.
			 */
			update_frameheadpos(winstate);

			update_frametailpos(winstate);
			abs_pos = winstate->frametailpos - 1;
			mark_pos = 0;		/* keep compiler quiet */
			forward = -1;
			break;
		default:
			elog(ERROR, "unrecognized window seek type: %d", seektype);
			abs_pos = mark_pos = 0; /* keep compiler quiet */
			break;
	}

	/*
	 * Get the next nonnull value in the frame, moving forward or backward
	 * until we find a value or reach the frame's end.
	 */

	/*
	 * 현재 행이 축소된 프레임 안에 있는지 확인한다.
	 */
	num_reduced_frame = row_is_in_reduced_frame(winobj, winstate->frameheadpos);
	if (num_reduced_frame < 0)	/* 매치되지 않았거나 건너뛴 행 */
		goto out_of_frame;
	else if (num_reduced_frame > 0) /* 축소된 프레임의 첫 행 */
	{
		/*
		 * 행이 축소된 프레임을 벗어났을 가능성을 미리 확인한다.  RPR 이
		 * 활성화되어 있으면 EXCLUDE 절을 지정할 수 없고 프레임은 항상
		 * 연속적이므로, 다음 검사를 안전하게 수행할 수 있다.  다만 중간에
		 * NULL 이 있으면 행이 축소된 프레임을 벗어나 있을 수 있으므로, 이는
		 * 아래의 do 루프에서 확인해야 한다.
		 */
		if (seektype == WINDOW_SEEK_HEAD && relpos >= num_reduced_frame)
			goto out_of_frame;
		if (seektype == WINDOW_SEEK_TAIL)
		{
			if (notnull_relpos >= num_reduced_frame)
				goto out_of_frame;

			/* 축소된 프레임을 벗어나지 않았다. abspos를 시작점으로 설정한다 */
			abs_pos = winstate->frameheadpos + num_reduced_frame - 1;
		}
	}

	do
	{
		int			inframe;
		int			v;

		/*
		 * Check apparent out of frame case.  We need to do this because we
		 * may not call window_gettupleslot before row_is_in_frame, which
		 * supposes abs_pos is never negative.
		 */
		if (abs_pos < 0)
			goto out_of_frame;

		/* check whether row is in frame */
		inframe = row_is_in_frame(winobj, abs_pos, slot, true);
		if (inframe == -1)
			goto out_of_frame;
		else if (inframe == 0)
			goto advance;

		if (isout)
			*isout = false;

		v = get_notnull_info(winobj, abs_pos, argno);
		if (v == NN_NULL)		/* this row is known to be NULL */
			goto advance;

		else if (v == NN_UNKNOWN)	/* need to check NULL or not */
		{
			if (!window_gettupleslot(winobj, abs_pos, slot))
				goto out_of_frame;

			econtext->ecxt_outertuple = slot;
			datum = ExecEvalExpr(
								 (ExprState *) list_nth(winobj->argstates,
														argno), econtext,
								 isnull);
			if (!*isnull)
				notnull_offset++;

			/* record the row status */
			put_notnull_info(winobj, abs_pos, argno, *isnull);
		}
		else					/* this row is known to be NOT NULL */
		{
			notnull_offset++;
			if (notnull_offset > notnull_relpos)
			{
				/* to prepare exiting this loop, datum needs to be set */
				if (!window_gettupleslot(winobj, abs_pos, slot))
					goto out_of_frame;

				econtext->ecxt_outertuple = slot;
				datum = ExecEvalExpr(
									 (ExprState *) list_nth
									 (winobj->argstates, argno),
									 econtext, isnull);
			}
		}
advance:
		abs_pos += forward;
		if (rpr_is_defined(winstate))
		{
			/*
			 * 여전히 축소된 프레임 안에 있는지 확인한다.  (대상 행을 가져오는
			 * 데 성공했는지도 함께 확인한다.)
			 */
			num_reduced_frame--;
			if (num_reduced_frame <= 0 && notnull_offset <= notnull_relpos)
				goto out_of_frame;
		}
	} while (notnull_offset <= notnull_relpos);

	if (set_mark)
		WinSetMarkPosition(winobj, mark_pos);

	return datum;

out_of_frame:
	if (isout)
		*isout = true;
	*isnull = true;
	return (Datum) 0;
}


/*
 * init_notnull_info
 * Initialize non null map.
 */
static void
init_notnull_info(WindowObject winobj, WindowStatePerFunc perfuncstate)
{
	int			numargs = perfuncstate->numArguments;

	if (winobj->ignore_nulls == PARSER_IGNORE_NULLS)
	{
		int			argno = 0;
		ListCell   *lc;

		winobj->notnull_info = palloc0_array(uint8 *, numargs);
		winobj->num_notnull_info = palloc0_array(int64, numargs);
		winobj->notnull_info_cacheable = palloc_array(bool, numargs);

		foreach(lc, perfuncstate->wfunc->args)
		{
			Node	   *arg = (Node *) lfirst(lc);

			winobj->notnull_info_cacheable[argno] =
				!contain_volatile_functions(arg) &&
				!contain_subplans(arg);

			argno++;
		}
	}
}

/*
 * grow_notnull_info
 * expand notnull_info if necessary.
 * pos: not null info position
 * argno: argument number
 */
static void
grow_notnull_info(WindowObject winobj, int64 pos, int argno)
{
/* initial number of notnull info members */
#define	INIT_NOT_NULL_INFO_NUM	128

	if (pos >= winobj->num_notnull_info[argno])
	{
		/* We may be called in a short-lived context */
		MemoryContext oldcontext = MemoryContextSwitchTo
			(winobj->winstate->ss.ps.ps_ExprContext->ecxt_per_query_memory);

		for (;;)
		{
			Size		oldsize = NN_POS_TO_BYTES
				(winobj->num_notnull_info[argno]);
			Size		newsize;

			if (oldsize == 0)	/* memory has not been allocated yet for this
								 * arg */
			{
				newsize = NN_POS_TO_BYTES(INIT_NOT_NULL_INFO_NUM);
				winobj->notnull_info[argno] = palloc0(newsize);
			}
			else
			{
				newsize = oldsize * 2;
				winobj->notnull_info[argno] =
					repalloc0(winobj->notnull_info[argno], oldsize, newsize);
			}
			winobj->num_notnull_info[argno] = NN_BYTES_TO_POS(newsize);
			if (winobj->num_notnull_info[argno] > pos)
				break;
		}
		MemoryContextSwitchTo(oldcontext);
	}
}

/*
 * get_notnull_info
 * retrieve a map
 * pos: map position
 * argno: argument number
 */
static uint8
get_notnull_info(WindowObject winobj, int64 pos, int argno)
{
	uint8	   *mbp;
	uint8		mb;
	int64		bpos;

	if (!winobj->notnull_info_cacheable[argno])
		return NN_UNKNOWN;

	grow_notnull_info(winobj, pos, argno);
	bpos = NN_POS_TO_BYTES(pos);
	mbp = winobj->notnull_info[argno];
	mb = mbp[bpos];
	return (mb >> (NN_SHIFT(pos))) & NN_MASK;
}

/*
 * put_notnull_info
 * update map
 * pos: map position
 * argno: argument number
 * isnull: indicate NULL or NOT
 */
static void
put_notnull_info(WindowObject winobj, int64 pos, int argno, bool isnull)
{
	uint8	   *mbp;
	uint8		mb;
	int64		bpos;
	uint8		val = isnull ? NN_NULL : NN_NOTNULL;
	int			shift;

	if (!winobj->notnull_info_cacheable[argno])
		return;

	grow_notnull_info(winobj, pos, argno);
	bpos = NN_POS_TO_BYTES(pos);
	mbp = winobj->notnull_info[argno];
	mb = mbp[bpos];
	shift = NN_SHIFT(pos);
	mb &= ~(NN_MASK << shift);	/* clear map */
	mb |= (val << shift);		/* update map */
	mbp[bpos] = mb;
}

/*
 * eval_nav_offset
 *		미리 만들어진 행 패턴 내비게이션 오프셋 ExprState 를 평가한다.
 *
 * 오프셋은 run-time 상수이므로(파서가 내비게이션 오프셋 안의 열 참조를
 * 거부한다) 스캔마다 한 번, 즉 어떤 매개변수든 바인딩될 때 평가된다.
 * 오프셋을 int64로 반환한다.  NULL 이거나 음수인 결과는 SQL 표준에 따라
 * 오류이다(fail-closed이며 스캔마다 다시 검사한다).  검증하지 않을 때는
 * NULL 을 -1 로 보고하여 음수 오프셋과 같은 경로를 타게 한다.
 */
static int64
eval_nav_offset(WindowAggState *winstate, ExprState *estate, bool validate)
{
	ExprContext *econtext = winstate->ss.ps.ps_ExprContext;
	Datum		val;
	bool		isnull;
	int64		offset;

	val = ExecEvalExprSwitchContext(estate, econtext, &isnull);

	if (isnull)
	{
		if (validate)
			ereport(ERROR,
					errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
					errmsg("row pattern navigation offset must not be null"));
		return -1;				/* 호출자가 도달 범위에서 이 값을 제외한다 */
	}

	offset = DatumGetInt64(val);

	if (offset < 0 && validate)
		ereport(ERROR,
				errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				errmsg("row pattern navigation offset must not be negative"));

	return offset;
}

/*
 * build_nav_offsets
 *		실행기 초기화 시점에 내비게이션별 오프셋 기록 항목을 만들고 그 오프셋
 *		인자 표현식을 컴파일한다.
 *
 * 오프셋은 여기서 평가하지 않는다: PARAM_EXEC 오프셋은(함수 인라이닝이나
 * LATERAL 참조로 인한 것으로) 노드가 (다시) 스캔될 때까지 값이 없다.  실제
 * 값은 calculate_frame_offsets()가 윈도우 프레임 경계를 다루는 방식과
 * 마찬가지로 resolve_nav_offsets()가 스캔마다 확정한다.
 */
static void
build_nav_offsets(RPRNavExpr *nav, WindowAggState *winstate)
{
	RPRNavOffsets *entry = palloc0_object(RPRNavOffsets);

	/*
	 * 파서가 보장하는 바(compute_matchStartDependent 와 대응): nav의 직계
	 * 자식은 결코 RPRNavExpr 이 아니다.  복합 중첩은 그 자리에서 평탄화되고,
	 * 다른 어떤 중첩도 거부된다.  따라서 outer 종류에 따른 분기만으로
	 * 충분하다.
	 */
	Assert(nav->arg == NULL || !IsA(nav->arg, RPRNavExpr));
	Assert(nav->offset_arg == NULL || !IsA(nav->offset_arg, RPRNavExpr));
	Assert(nav->compound_offset_arg == NULL ||
		   !IsA(nav->compound_offset_arg, RPRNavExpr));

	entry->nav = nav;
	if (nav->offset_arg != NULL)
		entry->offset_state = ExecInitExpr(nav->offset_arg,
										   (PlanState *) winstate);
	if (nav->compound_offset_arg != NULL)
		entry->compound_offset_state = ExecInitExpr(nav->compound_offset_arg,
													(PlanState *) winstate);

	/*
	 * 컴파일된 내비게이션의 실행 상태를 소유한다.  이후 ExecInitExprRec()가
	 * 실행 되어 nav->navno로 이 항목에 접근하며, 오프셋은
	 * resolve_nav_offsets()가 이번 스캔에 대해 확정하기 전까지는 설정되지
	 * 않은 채로 남는다.
	 */
	entry->rprnavstate = makeNode(RPRNavState);
	entry->rprnavstate->winstate = winstate;
	entry->rprnavstate->rprnavexpr = nav;
	entry->rprnavstate->offset.isnull = true;
	entry->rprnavstate->offset.value = (Datum) 0;
	entry->rprnavstate->compound_offset.isnull = true;
	entry->rprnavstate->compound_offset.value = (Datum) 0;

	winstate->rprNavOffsets = lappend(winstate->rprNavOffsets, entry);
}

static bool
nav_offsets_walker(Node *node, WindowAggState *winstate)
{
	if (node == NULL)
		return false;
	if (IsA(node, RPRNavExpr))
		build_nav_offsets(castNode(RPRNavExpr, node), winstate);

	return expression_tree_walker(node, nav_offsets_walker, winstate);
}

/*
 * build_define_offsets
 *		실행기 초기화 시점에 DEFINE 절의 내비게이션마다 RPRNavOffsets 항목을
 *		하나씩 만들고 그 오프셋 인자 표현식을 컴파일한다.
 *
 * 항목들은 순회 순서, 즉 compute_define_metadata()가 번호를 매긴 순서대로
 * 추가되므로, 항목 i는 navno가 i인 내비게이션이다.
 *
 * 실제 오프셋 값과 그로부터 얻는 tuplestore 트림 경계는 나중에 스캔마다
 * resolve_nav_offsets()가 확정한다. 이 함수에는 RPR 윈도우만 도달한다.
 */
static void
build_define_offsets(WindowAggState *winstate, List *defineClause)
{
	EvalDefineOffsetsContext ctx;

	/* DEFINE 은 필수이므로 RPR 윈도우에는 항상 이 절이 있다 */
	Assert(defineClause != NIL);

	foreach_node(TargetEntry, te, defineClause)
	{
		nav_offsets_walker((Node *) te->expr, winstate);
	}

	/*
	 * 플랜 타임에 이미 상수인 오프셋을 확정해 두어, (결코 실행되지 않으므로
	 * resolve_nav_offsets()에도 도달하지 않는) EXPLAIN 이 실제 트림 경계를
	 * 표시할 수 있게 한다.  매개변수화된 오프셋(일반 플랜에서의 PARAM_EXTERN
	 * 이나 PARAM_EXEC)은 아직 값이 없으므로 resolve_nav_offsets()가 스캔마다
	 * 경계를 정하도록 남겨 둔다.
	 */
	ctx.winstate = winstate;
	ctx.maxOffset = 0;
	ctx.maxOverflow = false;
	ctx.minFirstOffset = PG_INT64_MAX;
	ctx.hasMax = false;
	ctx.hasFirst = false;
	ctx.validate = false;		/* 초기화 시점의 확정은 EXPLAIN 표시
								 * 전용이다 */

	foreach_ptr(RPRNavOffsets, entry, winstate->rprNavOffsets)
	{
		RPRNavExpr *nav = entry->nav;
		bool		is_const;

		/*
		 * PREV(v, 1 + 1)처럼 접을 수 있는 오프셋은,
		 * eval_const_expressions()가 내비게이션 내부까지 도달해 여기에
		 * Const를 남겨둔 경우에만 고정된 것으로 취급한다.  이는 표현식 트리
		 * 뮤테이터가 대신 해 준다.
		 */
		is_const = (nav->offset_arg == NULL || IsA(nav->offset_arg, Const)) &&
			(nav->compound_offset_arg == NULL ||
			 IsA(nav->compound_offset_arg, Const));

		if (is_const)
		{
			/* 상수 오프셋: EXPLAIN 과 스캔 모두에 대해 지금 확정할 수 있다 */
			resolve_one_nav(entry, &ctx);
		}
		else
		{
			/*
			 * 매개변수화된 오프셋(바인드된 PARAM_EXTERN, 또는 SRF/함수
			 * 인라이닝을 통한 상관된 PARAM_EXEC)은 초기화 시점에는 믿을 수
			 * 있는 값이 없다.  윈도우 프레임 오프셋과 마찬가지로 실행 시
			 * resolve_nav_offsets()가 확정하며, EXPLAIN 은 "runtime"으로
			 * 표시한다.
			 */
			if (nav->kind == RPR_NAV_PREV || nav->kind == RPR_NAV_LAST ||
				nav->kind == RPR_NAV_PREV_LAST || nav->kind == RPR_NAV_NEXT_LAST)
			{
				ctx.hasMax = true;
				winstate->navMaxOffsetKind = RPR_NAV_OFFSET_NEEDS_EVAL;
			}
			if (nav->kind == RPR_NAV_FIRST || nav->kind == RPR_NAV_PREV_FIRST ||
				nav->kind == RPR_NAV_NEXT_FIRST)
			{
				ctx.hasFirst = true;
				winstate->navFirstOffsetKind = RPR_NAV_OFFSET_NEEDS_EVAL;
			}
		}
	}

	if (ctx.maxOverflow)
	{
		/*
		 * 상수나 바인드 값의 오버플로는, 매개변수가 이미 이 차원을
		 * "runtime"으로 만들지 않은 한(표시상 NEEDS_EVAL 이 우선한다)
		 * retain-all을 강제한다.
		 */
		if (winstate->navMaxOffsetKind != RPR_NAV_OFFSET_NEEDS_EVAL)
			winstate->navMaxOffsetKind = RPR_NAV_OFFSET_RETAIN_ALL;
	}
	else
		winstate->navMaxOffset = ctx.maxOffset;

	winstate->hasMaxNav = ctx.hasMax;

	/* minFirstOffset 는 FIRST 가 없으면 여전히 PG_INT64_MAX 이다 */
	winstate->hasFirstNav = ctx.hasFirst;
	winstate->navFirstOffset = ctx.minFirstOffset;
}

/*
 * resolve_one_nav
 *		현재 스캔에 대해 한 내비게이션의 오프셋을 평가하고, 확정된 값을 그
 *		RPRNavState 에 고정하며, tuplestore 트림 크기를 정하는 데 쓰이는
 *		후방/전방 도달 거리를 누적한다.
 */
static void
resolve_one_nav(RPRNavOffsets *entry, EvalDefineOffsetsContext *context)
{
	RPRNavExpr *nav = entry->nav;
	int64		inner;
	int64		outer;

	/* 내부 오프셋 */
	if (entry->offset_state != NULL)
		inner = eval_nav_offset(context->winstate, entry->offset_state,
								context->validate);
	else if (nav->kind == RPR_NAV_PREV || nav->kind == RPR_NAV_NEXT)
		inner = 1;
	else
		inner = 0;

	/* 외부(복합) 오프셋 */
	if (entry->compound_offset_state != NULL)
		outer = eval_nav_offset(context->winstate, entry->compound_offset_state,
								context->validate);
	else
		outer = 1;

	/*
	 * 음수이거나, null이어서 -1 로 보고되는 오프셋은 실행 시 거부된다.  그
	 * 시점이면 이미 eval_nav_offset()이 여기 도달하기 전에 오류를 일으켰을
	 * 것이므로, 이 내비게이션은 결코 실행될 수 없고 행을 유지할 필요도 없다.
	 * 이런 값은 두 도달 거리 모두에서 제외하는데, 그러면 아래 계산이 음수
	 * 아닌 피연산자만 다루게 되는 효과도 있다.
	 */
	if (inner < 0 || outer < 0)
	{
		Assert(!context->validate);
		return;
	}

	/*
	 * 확정된 값을 컴파일된 내비게이션의 RPRNavState 에 고정하여,
	 * ExecEvalRPRNavSet()이 행마다 오프셋을 다시 평가하는 대신 이번 스캔의
	 * 상수를 읽도록 한다.
	 */
	entry->rprnavstate->offset.isnull = false;
	entry->rprnavstate->offset.value = Int64GetDatum(inner);
	entry->rprnavstate->compound_offset.isnull = false;
	entry->rprnavstate->compound_offset.value = Int64GetDatum(outer);

	/*
	 * 후방 도달: 기본값 0 을 포함한 모든 오프셋에서의 PREV, LAST, 그리고 복합
	 * PREV_LAST/NEXT_LAST.
	 */
	if (nav->kind == RPR_NAV_PREV ||
		nav->kind == RPR_NAV_LAST ||
		nav->kind == RPR_NAV_PREV_LAST ||
		nav->kind == RPR_NAV_NEXT_LAST)
	{
		context->hasMax = true;

		if (!context->maxOverflow)
		{
			int64		reach = 0;

			if (nav->kind == RPR_NAV_PREV || nav->kind == RPR_NAV_LAST)
				reach = inner;
			else if (nav->kind == RPR_NAV_PREV_LAST)
			{
				if (pg_add_s64_overflow(inner, outer, &reach))
					context->maxOverflow = true;
			}
			else
				reach = Max(inner - outer, 0);

			if (!context->maxOverflow)
				context->maxOffset = Max(context->maxOffset, reach);
		}
	}

	/* match_start 로부터의 전방 도달: FIRST, 복합 PREV_FIRST/NEXT_FIRST */
	if (nav->kind == RPR_NAV_FIRST ||
		nav->kind == RPR_NAV_PREV_FIRST ||
		nav->kind == RPR_NAV_NEXT_FIRST)
	{
		int64		reach;

		context->hasFirst = true;

		if (nav->kind == RPR_NAV_FIRST)
			reach = inner;
		else if (nav->kind == RPR_NAV_PREV_FIRST)
			reach = inner - outer;	/* 둘 다 >= 0 이므로 int64 언더플로가 될
									 * 수 없다 */
		else
		{
			/* NEXT_FIRST: inner + outer는 항상 >= 0 이다. 오버플로
			 * 시 clamp한다 */
			if (pg_add_s64_overflow(inner, outer, &reach))
				reach = PG_INT64_MAX;
		}

		context->minFirstOffset = Min(context->minFirstOffset, reach);
	}
}

/*
 * resolve_nav_offsets
 *		현재 스캔에 대해 모든 내비게이션 오프셋을 확정하고 tuplestore 트림
 *		경계를 WindowAggState 에 저장한다.
 *
 * ExecWindowAgg 에서 첫 호출 시와 매 rescan 이후에 호출되는데, 이는
 * calculate_frame_offsets()가 윈도우 프레임 경계를 확정하는 곳과 같은
 * 지점이다.  그 시점이면 모든 매개변수(PARAM_EXTERN 과 PARAM_EXEC 모두)가
 * 바인딩되어 있고 오프셋은 run-time 상수이므로, 스캔마다 한 번씩만 평가하면
 * 충분하다.  이렇게 하면 매개변수화된 오프셋에 대해서도 트림이 유한하게
 * 유지되고(retain-all 없이), 매 스캔마다 (fail-closed로) 다시 검증된다.
 */
static void
resolve_nav_offsets(WindowAggState *winstate)
{
	EvalDefineOffsetsContext ctx;

	/* 지금 요청을 처리하므로 스캔별 대기 플래그를 지운다 */
	winstate->navResolvePending = false;

	winstate->navMaxOffset = 0;
	winstate->navMaxOffsetKind = RPR_NAV_OFFSET_FIXED;
	winstate->hasMaxNav = false;
	winstate->hasFirstNav = false;
	winstate->navFirstOffset = 0;
	winstate->navFirstOffsetKind = RPR_NAV_OFFSET_FIXED;

	/* 이 요청은 내비게이션을 가진 윈도우에 대해서만 보류된다 */
	Assert(winstate->rprNavOffsets != NIL);

	ctx.winstate = winstate;
	ctx.maxOffset = 0;
	ctx.maxOverflow = false;
	ctx.minFirstOffset = PG_INT64_MAX;
	ctx.hasMax = false;
	ctx.hasFirst = false;
	ctx.validate = true;		/* 실행: null/음수에 대해 fail-closed */

	foreach_ptr(RPRNavOffsets, entry, winstate->rprNavOffsets)
	{
		resolve_one_nav(entry, &ctx);
	}

	/*
	 * 후방(PREV/LAST) 도달.  int64 오버플로가 나면 lookback의 한계를 정할 수
	 * 없으므로 이 차원을 RETAIN_ALL 로 표시한다.  advance_nav_mark()가 이를
	 * 읽어 tuplestore 트림을 비활성화한다.
	 */
	if (ctx.maxOverflow)
		winstate->navMaxOffsetKind = RPR_NAV_OFFSET_RETAIN_ALL;
	else
		winstate->navMaxOffset = ctx.maxOffset;

	winstate->hasMaxNav = ctx.hasMax;

	/* 전방(FIRST) 도달. retain-all sentinel이 필요 없다 */
	winstate->hasFirstNav = ctx.hasFirst;
	winstate->navFirstOffset = ctx.minFirstOffset;
}

/*
 * rpr_is_defined
 * 행 패턴 인식이 정의되어 있으면 true를 반환한다.
 */
static bool
rpr_is_defined(WindowAggState *winstate)
{
	return winstate->rpPattern != NULL;
}

/*
 * -----------------
 * row_is_in_reduced_frame
 * 현재 행의 축소된 윈도우 프레임 안에 행 패턴 매칭에 따라 어떤 행이 있는지를
 * 판단한다
 *
 * pos가 아직 결정되지 않았다면, ensure_reduced_frame()이 먼저 매치를 앞으로
 * 구동한다.
 *
 * 반환값:
 * = 0, RPR 이 정의되어 있지 않다.  >0, 행이 축소된 프레임의 첫 행이면. 축소된
 * 프레임에 있는 행 수를 반환한다.
 * -1, 행이 매치되지 않았거나 빈 매치를 시작하는 경우
 * -2, 행이 현재 매치 안에 있지만 그 첫 행이 아닌 경우(매치의 내부 행)
 * -----------------
 */
static int64
row_is_in_reduced_frame(WindowObject winobj, int64 pos)
{
	WindowAggState *winstate = winobj->winstate;
	int			state;
	int64		rtn;

	if (!rpr_is_defined(winstate))
	{
		/*
		 * RPR 이 정의되어 있지 않다.  항상 축소된 윈도우 프레임 안에 있다고
		 * 가정한다.
		 */
		rtn = 0;
		return rtn;
	}

	ensure_reduced_frame(winobj, pos);

	state = get_reduced_frame_status(winstate, pos);

	switch (state)
	{
		case RF_FRAME_HEAD:
			rtn = winstate->rpr_match_length;
			break;

		case RF_SKIPPED:
			rtn = -2;
			break;

		case RF_UNMATCHED:
		case RF_EMPTY_MATCH:
			rtn = -1;
			break;

		default:
			elog(ERROR, "unrecognized state: %d at: " INT64_FORMAT,
				 state, pos);
			break;
	}

	return rtn;
}

/*
 * ensure_reduced_frame
 *		pos가 확정되도록 행 패턴 매치를 앞으로 구동한다.
 *
 * 멱등적이다: 이미 결정된 pos는 그대로 둔다.  그래서 호출자는 같은 행에 대해
 * 이 함수를 반복 호출할 수 있다(행 스캔을 따라가기 위해 행마다 한 번, 그리고
 * 윈도우 함수가 프레임에 접근할 때 다시 한 번).
 */
static void
ensure_reduced_frame(WindowObject winobj, int64 pos)
{
	WindowAggState *winstate = winobj->winstate;

	if (get_reduced_frame_status(winstate, pos) == RF_NOT_DETERMINED)
	{
		update_frameheadpos(winstate);
		update_reduced_frame(winobj, pos);
	}
}

/*
 * clear_reduced_frame
 * 축소된 프레임 상태를 지운다.
 */
static void
clear_reduced_frame(WindowAggState *winstate)
{
	winstate->rpr_match_start = -1; /* start < 0: 아직 결정된 결과가 없음 */
	winstate->rpr_match_length = -1;
}

/*
 * get_reduced_frame_status
 *		위치를 현재 매치와 대조해 조회한다.
 *
 * 다음 RF_* 상수 중 하나를 반환한다:
 *   RF_NOT_DETERMINED  pos가 아직 처리되지 않음
 *   RF_FRAME_HEAD      pos가 현재 매치의 시작
 *   RF_SKIPPED         pos가 현재 매치 안에 있지만 시작은 아님
 *   RF_UNMATCHED       pos가 처리되었지만 어떤 매치에도 속하지 않음
 *   RF_EMPTY_MATCH     pos가 빈(길이 0 인) 매치의 시작
 *
 * 결과 슬롯은 두 필드에 걸쳐 네 가지 상태를 인코딩하며, 별도의
 * "valid"/"matched" 플래그는 없다:
 *
 *   start < 0                 결정되지 않음 (지워진 슬롯)
 *   start >= 0, length == -1  매치되지 않음 (시작 행만 포함)
 *   start >= 0, length == 0   빈 매치 (시작 위치의 길이 0 매치)
 *   start >= 0, length >= 1  [start, start + length) 구간의 실제 매치
 */
static int
get_reduced_frame_status(WindowAggState *winstate, int64 pos)
{
	int64		start = winstate->rpr_match_start;
	int64		length = winstate->rpr_match_length;

	Assert(pos >= 0);
	Assert(start < 0 || length >= -1);

	/* 지워진 슬롯: 아직 기록된 결과가 없음 */
	if (start < 0)
		return RF_NOT_DETERMINED;

	/*
	 * 레코드 자신의 행: length가 곧바로 결론을 알려주며, 다른 어떤 행도 이 세
	 * 가지 중 어느 것도 만들어낼 수 없다.
	 */
	if (pos == start)
	{
		if (length == -1)
			return RF_UNMATCHED;
		if (length == 0)
			return RF_EMPTY_MATCH;
		return RF_FRAME_HEAD;
	}

	/*
	 * 그 외의 모든 행은 오직 [start, start + length) 구간의 실제 매치로만
	 * 덮인다.  sentinel 값은 별도로 다룰 필요가 없다: -1 과 0 은 그 구간을
	 * 비워 두므로, start가 아닌 모든 pos는 자연히 여기로 떨어진다.
	 */
	if (pos < start || pos >= start + length)
		return RF_NOT_DETERMINED;

	/* 실제 매치 안, head 다음 위치 */
	return RF_SKIPPED;
}

/*
 * advance_nav_mark
 *		RPR 내비게이션 mark를 전진시킨다. 이 mark는 NFA 의
 *		frontier(currentPos)에서 유도하되 내비게이션의 후방 도달 거리만큼
 *		뒤에서 따라가므로, tuplestore_trim()이 내비게이션으로 더 이상 도달할
 *		수 없는 행을 해제할 수 있다.
 *
 * nav read 포인터는 집계용 및 함수별 read 포인터와 독립적이므로, 이 mark를
 * 움직여도 그것들의 fetch에는 영향이 없다.  오직 DEFINE 절 자신의
 * PREV/LAST/FIRST 조회만을 제한한다.  후방 도달(PREV/LAST)은 frontier로부터
 * 측정한다.  반면 FIRST 는 head 컨텍스트의 matchStartRow 로부터 거꾸로
 * 도달하므로 별도로 제한하며, FIRST 가 없으면 mark는 frontier를 자유롭게
 * 따라갈 수 있다.
 */
static void
advance_nav_mark(WindowAggState *winstate, int64 currentPos)
{
	int64		navmarkpos;

	/* 모든 RPR 윈도우는 내비게이션용 read 포인터를 가진다 */
	Assert(winstate->nav_winobj != NULL);

	/* RETAIN_ALL(오프셋 오버플로)은 후방 차원에 대한 트림을 비활성화한다 */
	if (winstate->navMaxOffsetKind == RPR_NAV_OFFSET_RETAIN_ALL)
		return;

	if (currentPos > winstate->navMaxOffset)
		navmarkpos = currentPos - winstate->navMaxOffset;
	else
		navmarkpos = 0;

	if (winstate->hasFirstNav && winstate->nfaContext != NULL)
	{
		int64		firstreach;

		/*
		 * head 컨텍스트는 (컨텍스트가 오름차순으로 추가되므로)
		 * matchStartRow 가 가장 작다.  따라서 head를 기준으로 경계를 잡으면
		 * 모든 FIRST 도달을 포괄한다.
		 */
		if (!pg_add_s64_overflow(winstate->nfaContext->matchStartRow,
								 winstate->navFirstOffset,
								 &firstreach))
			navmarkpos = Min(navmarkpos, Max(firstreach, 0));
	}

	if (navmarkpos > winstate->nav_winobj->markpos)
		WinSetMarkPosition(winstate->nav_winobj, navmarkpos);
}

/*
 * advance_reduced_frame_nfa
 *		targetCtx 가 완료되거나 파티션이 끝날 때까지 NFA 를 전진시킨다.
 *
 * 이 함수는 매치 드라이버로, update_reduced_frame()에서 분리되어 나온 것이다.
 * update_reduced_frame()은 이 함수를 호출해 매치를 전진시킨 다음 확정된
 * 결과를 기록한다.  행 평가는 모든 활성 컨텍스트가 공유한다.
 */
static void
advance_reduced_frame_nfa(WindowObject winobj, RPRNFAContext *targetCtx)
{
	WindowAggState *winstate = winobj->winstate;
	int64		currentPos;
	int64		startPos;
	int64		saved_currentpos = winstate->currentpos;

	/*
	 * 처리를 시작할 위치를 정한다.  보통은 컨텍스트가 처리 중 currentPos+1
	 * 위치에서 만들어지므로 nfaLastProcessedRow+1 >= matchStartRow 이다.
	 * 그러나 update_reduced_frame()이 nfaLastProcessedRow 보다 뒤의 pos에
	 * 대해 필요에 따라 만드는 컨텍스트는 그보다 더 뒤에서 시작할 수 있다.
	 */
	startPos = Max(targetCtx->matchStartRow,
				   winstate->nfaLastProcessedRow + 1);

	/*
	 * 대상 컨텍스트가 완료되거나 경계에 부딪힐 때까지 행을 처리한다.  각 행
	 * 평가는 모든 활성 컨텍스트가 공유한다.
	 *
	 * winstate->currentpos는 행 전체에 대해 스캔 위치로 설정되고
	 * ExecRPRProcessRow 동안 그대로 유지되는데, DEFINE 술어가 매칭
	 * 중(nfa_eval_var_match) 지연 평가되며 그 EEOP_RPR_NAV_SET opcode가
	 * currentpos를 읽기 때문이다. 이 값은 루프가 끝난 뒤 복원된다.
	 */
	for (currentPos = startPos; targetCtx->states != NULL; currentPos++)
	{
		/*
		 * 이 행에 대한 변수를 평가한다.  한 번만 수행하며 모든 컨텍스트가
		 * 공유한다.
		 *
		 * FIRST/LAST 내비게이션을 위해 nav_match_start 를 head 컨텍스트의
		 * matchStartRow 로 설정한다.  Match_start 에 의존하는 변수(FIRST,
		 * 오프셋이 있는 LAST)는 matchStartRow 가 다를 때
		 * ExecRPRProcessRow 에서 컨텍스트별로 다시 평가된다.
		 */
		winstate->currentpos = currentPos;
		winstate->nav_match_start = targetCtx->matchStartRow;

		/* 파티션에 더 이상 행이 없는가? 모든 컨텍스트를 마무리한다 */
		if (!rpr_prepare_row(winobj, currentPos, winstate->nfaVarMatched))
		{
			ExecRPRFinalizeAllContexts(winstate, currentPos - 1);
			/* 마무리로 죽은 컨텍스트를 정리한다 */
			ExecRPRCleanupDeadContexts(winstate, targetCtx);
			break;
		}

		/* 마지막으로 처리한 행을 갱신한다 */
		winstate->nfaLastProcessedRow = currentPos;

		/*--------------------------
		 * 이 행에 대해 모든 컨텍스트를 처리한다:
		 *   1. 전부 매치 (수렴)
		 *   2. 중복 흡수
		 *   3. 전부 확장 (발산)
		 */
		ExecRPRProcessRow(winstate, currentPos);

		/*
		 * 다음에 시작할 수 있는 위치를 위해 새 컨텍스트를 만든다.  이는 SKIP
		 * TO NEXT ROW 를 위한 겹치는 매치 감지를 가능하게 한다.
		 */
		ExecRPRStartContext(winstate, currentPos + 1);

		/*
		 * (활성 상태도 매치도 없이 실패한) 죽은 컨텍스트를 정리한다.  처리 중
		 * 실패한 컨텍스트를 제거하며, 이를 프루닝됨 또는 불일치로 적절히
		 * 집계한다.
		 */
		ExecRPRCleanupDeadContexts(winstate, targetCtx);

		/*
		 * 트림이 오래된 행을 해제할 수 있도록 nav mark를 frontier까지
		 * 전진시킨다.
		 */
		advance_nav_mark(winstate, currentPos);
	}

	/*
	 * NFA 스캔을 위해 빌려 온 출력 행 위치를 복원한다.
	 */
	winstate->currentpos = saved_currentpos;
}

/*
 * update_reduced_frame
 *		다중 컨텍스트 NFA 패턴 매칭을 사용해 축소된 프레임 정보를 갱신한다.
 *
 * 가능한 매치 시작 위치마다 하나씩, 여러 NFA 컨텍스트를 동시에 유지한다.
 * 이를 통해 컨텍스트 사이에 행 평가를 공유할 수 있어 SKIP TO NEXT ROW
 * 모드에서 되감을 때 중복된 DEFINE 절 평가를 피한다.
 *
 * 핵심 최적화:
 * - 행 평가(비용이 큰 DEFINE 절)는 행마다 한 번만 일어난다
 * - 모든 활성 컨텍스트가 같은 평가 결과를 공유한다
 * - 컨텍스트는 호출 사이에도 유지되어 O(n) DEFINE 평가를 가능하게 한다
 */
static void
update_reduced_frame(WindowObject winobj, int64 pos)
{
	WindowAggState *winstate = winobj->winstate;
	RPRNFAContext *targetCtx = NULL;

	winstate->rpr_match_start = pos;
	winstate->rpr_match_length = -1;

	if (winstate->nfaContext != NULL)
	{
		/*
		 * 경우 1: pos가 기존 컨텍스트의 시작 위치보다 앞이다.  이는 이 위치가
		 * 이미 처리되어 매치되지 않은 것으로 결정되었음을 뜻한다.  컨텍스트는
		 * 뒤쪽에 증가하는 위치로 추가되므로, head가 가장
		 * 오래된(matchStartRow 가 가장 작은) 컨텍스트이다.
		 */
		if (winstate->nfaContext->matchStartRow > pos)
			return;

		/*
		 * 경우 2: head 컨텍스트가 정확히 pos에서 시작한다. 이 컨텍스트는 이
		 * 행의 보류 중인 결과를 담고 있는데, 아직 진행 중이거나 이전 호출의
		 * 드라이버 루프에서 이미 완료된 것이다.  이후의 컨텍스트는 해당될 수
		 * 없다: 리스트는 matchStartRow 오름차순이기 때문이다.
		 */
		if (winstate->nfaContext->matchStartRow == pos)
			targetCtx = winstate->nfaContext;
	}

	if (targetCtx == NULL)
	{
		/*
		 * 컨텍스트가 존재하지 않는다.  pos가 이미 처리되었다면, 이 행은 이미
		 * 매치되지 않았거나 건너뛴 것으로 결정된 것이므로 다시 처리할 필요가
		 * 없다.
		 */
		if (pos <= winstate->nfaLastProcessedRow)
			return;

		/* 아직 처리되지 않았다. 새 컨텍스트를 만들어 새로 시작한다 */
		targetCtx = ExecRPRStartContext(winstate, pos);
	}

	/*
	 * 위의 두 분기 중 어느 쪽이든 targetCtx 를 pos로 확정하며, 드라이버는
	 * 이를 근거로 재개하고 맨 위에서 기록한 결과도 이를 키로 삼는다.
	 */
	Assert(pos == targetCtx->matchStartRow);

	/*
	 * 이 컨텍스트가 이전 호출에서 이미 완료된 경우가 아니라면 NFA 를 앞으로
	 * 구동한다.  이는 어떤 skip 모드에서든 일어날 수 있는데, 드라이버가 더
	 * 오래된 컨텍스트를 대신해 행을 실행하는 동안 겹치는 컨텍스트가 자신의
	 * 시작 행에 대한 호출이 오기도 전에 완료될 수 있기 때문이다.  그때 기록된
	 * 결과는 아래에서 등록한다.
	 */
	if (targetCtx->states != NULL)
		advance_reduced_frame_nfa(winobj, targetCtx);

	if (targetCtx->matchedState == NULL)
	{
		/* 매치 없음 */
		winstate->rpr_match_length = -1;
		ExecRPRRecordContextFailure(winstate,
									targetCtx->lastProcessedRow - targetCtx->matchStartRow + 1);
	}
	else
	{
		/*
		 * 매치됨: 빈 매치는 matchStartRow - 1 에서 끝나므로 행 수는 별도의
		 * 경우 없이 0 으로 나온다.  그보다 더 일찍 끝나는 경우는 없다.
		 * FIN 은 행을 소비하거나, 아니면 첫 행 이전에 도달하기 때문이다.
		 */
		Assert(targetCtx->matchEndRow >= targetCtx->matchStartRow - 1);

		winstate->rpr_match_length =
			targetCtx->matchEndRow - targetCtx->matchStartRow + 1;

		ExecRPRRecordContextSuccess(winstate, winstate->rpr_match_length);
	}

	/*
	 * pos에 대한 결과를 기록했다.  매치 여부와 관계없이 이 컨텍스트는 다 쓴
	 * 것이므로 해제한다.
	 */
	ExecRPRFreeContext(winstate, targetCtx);
}

/*
 * rpr_prepare_row
 *
 * 현재 행에 대한 DEFINE 평가 컨텍스트를 준비하고 행별 3 치 캐시를
 * RPR_VAR_UNEVALUATED 로 재설정한다.  행이 존재하면 true, 파티션을 벗어났으면
 * false를 반환한다.
 *
 * DEFINE 술어는 여기서 평가하지 않는다.  각 변수는 NFA 가 그것을 처음 소비할
 * 때(nfa_eval_var_match) 지연 평가되므로, 이 행에서 어떤 활성 상태도 검사하지
 * 않는 변수는 결코 평가되지 않는다.  호출자(advance_reduced_frame_nfa)는 행
 * 전체에 대해 winstate->currentpos를 pos로 설정하므로, 지연 평가의
 * EEOP_RPR_NAV_SET opcode가 대상 위치(currentpos +/- 오프셋)를 올바르게
 * 계산한다.
 *
 * 1-slot 모델을 사용한다: ecxt_outertuple 만 현재 행으로 설정된다.
 * PREV/NEXT/FIRST/LAST 내비게이션은 표현식 평가 중 슬롯을 일시적으로 바꾸는
 * EEOP_RPR_NAV_SET/RESTORE opcode가 처리한다.
 */
static bool
rpr_prepare_row(WindowObject winobj, int64 pos, RPRVarMatch *varMatched)
{
	WindowAggState *winstate = winobj->winstate;
	ExprContext *econtext = winstate->rprContext;
	TupleTableSlot *slot;

	/* 현재 행을 temp_slot_1 로 가져온다 */
	slot = winstate->temp_slot_1;
	if (!window_gettupleslot(winobj, pos, slot))
		return false;			/* 행이 존재하지 않음 */

	/* 1-slot 컨텍스트를 준비한다: ecxt_outertuple 만 설정 */
	econtext->ecxt_outertuple = slot;

	/* PREV/NEXT 가 새 행에 대해 다시 가져오도록 nav_slot 캐시를 무효화한다 */
	winstate->nav_slot_pos = -1;

	/*
	 * 행별 캐시를 "unevaluated"로 재설정한다.  각 변수의 DEFINE 은
	 * nfa_eval_var_match 에서 처음 소비될 때 지연 평가된다.
	 */
	memset(varMatched, 0,
		   sizeof(RPRVarMatch) * list_length(winstate->defineClauseExprs));

	return true;				/* 행이 존재함 */
}

/*
 * WinGetSlotInFrame
 * slot: 결과를 담을 TupleTableSlot
 * relpos: seek 위치로부터의 부호 있는 행 수 오프셋
 * seektype: WINDOW_SEEK_HEAD 또는 WINDOW_SEEK_TAIL
 * set_mark: 행을 찾았거나(또는 프레임 안에 있고) set_mark 가 true이면, 그 부수
 *		효과로 mark가 그 행으로 옮겨진다.
 * isnull: 출력 인자.  결과의 isnull 상태를 받는다
 * isout: 출력 인자.  대상 행 위치가 프레임을 벗어났는지를 나타내도록 설정된다
 *		(호출자가 신경 쓰지 않으면 NULL 을 넘겨도 된다)
 *
 * 슬롯을 성공적으로 가져왔으면 0 을, 프레임을 벗어났으면 0 이 아닌 값을
 * 반환한다.  (후자의 경우 isout도 함께 설정된다.)
 */
static int
WinGetSlotInFrame(WindowObject winobj, TupleTableSlot *slot,
				  int relpos, int seektype, bool set_mark,
				  bool *isnull, bool *isout)
{
	WindowAggState *winstate;
	int64		abs_pos;
	int64		mark_pos;
	int64		num_reduced_frame;

	Assert(WindowObjectIsValid(winobj));
	winstate = winobj->winstate;

	switch (seektype)
	{
		case WINDOW_SEEK_CURRENT:
			elog(ERROR, "WINDOW_SEEK_CURRENT is not supported for WinGetFuncArgInFrame");
			abs_pos = mark_pos = 0; /* 컴파일러 경고를 막기 위함 */
			break;
		case WINDOW_SEEK_HEAD:
			/* relpos < 0 을 거부하면 간단하고 아래 코드가 단순해진다 */
			if (relpos < 0)
				goto out_of_frame;
			update_frameheadpos(winstate);
			abs_pos = winstate->frameheadpos + relpos;
			mark_pos = abs_pos;

			/*
			 * 제외 옵션이 활성화되어 있다면 이를 반영하되, mark_pos 가 아니라
			 * abs_pos 만 전진시킨다.  이렇게 하면 현재 행의 peer 그룹이
			 * 바뀌어 이전 mark 위치보다 앞의 행을 가져오려는 시도로 이어지는
			 * 것을 막는다.
			 *
			 * 현재 행이 프레임 밖에 있는 것과 같은 일부 극단적인 경우에는 이
			 * 계산이 이론적으로는 지나치게 단순하지만, 어차피 그 행을 프레임
			 * 밖이라고 결론짓게 되므로 문제가 되지 않는다.  프레임 끝을 지난
			 * 행을 가져오는 것을 피하려 하지 않는데, 어차피 일부 경우에는
			 * 그런 일이 일어나기 때문이다.
			 */
			switch (winstate->frameOptions & FRAMEOPTION_EXCLUSION)
			{
				case 0:
					/* 조정이 필요 없음 */
					break;
				case FRAMEOPTION_EXCLUDE_CURRENT_ROW:
					if (abs_pos >= winstate->currentpos &&
						winstate->currentpos >= winstate->frameheadpos)
						abs_pos++;
					break;
				case FRAMEOPTION_EXCLUDE_GROUP:
					update_grouptailpos(winstate);
					if (abs_pos >= winstate->groupheadpos &&
						winstate->grouptailpos > winstate->frameheadpos)
					{
						int64		overlapstart = Max(winstate->groupheadpos,
													   winstate->frameheadpos);

						abs_pos += winstate->grouptailpos - overlapstart;
					}
					break;
				case FRAMEOPTION_EXCLUDE_TIES:
					update_grouptailpos(winstate);
					if (abs_pos >= winstate->groupheadpos &&
						winstate->grouptailpos > winstate->frameheadpos)
					{
						int64		overlapstart = Max(winstate->groupheadpos,
													   winstate->frameheadpos);

						if (abs_pos == overlapstart)
							abs_pos = winstate->currentpos;
						else
							abs_pos += winstate->grouptailpos - overlapstart - 1;
					}
					break;
				default:
					elog(ERROR, "unrecognized frame option state: 0x%x",
						 winstate->frameOptions);
					break;
			}
			num_reduced_frame = row_is_in_reduced_frame(winobj,
														winstate->frameheadpos);
			if (num_reduced_frame < 0)
				goto out_of_frame;
			else if (num_reduced_frame > 0)
				if (relpos >= num_reduced_frame)
					goto out_of_frame;
			break;
		case WINDOW_SEEK_TAIL:
			/* relpos > 0 을 거부하면 간단하고 아래 코드가 단순해진다 */
			if (relpos > 0)
				goto out_of_frame;

			/*
			 * RPR 은 프레임 head 위치에 신경 쓴다.  update_frameheadpos 를
			 * 호출해야 한다.
			 */
			update_frameheadpos(winstate);

			update_frametailpos(winstate);
			abs_pos = winstate->frametailpos - 1 + relpos;

			/*
			 * 제외 옵션이 활성화되어 있다면 이를 반영한다.  제외가 없다면
			 * 접근한 행에 안전하게 mark를 설정할 수 있다.  하지만 있다면
			 * 프레임 시작 지점에만 mark를 둘 수 있는데, 제외로 인해 나중에
			 * 프레임 안쪽으로 얼마나 더 되돌아가 가져와야 할지 알 수 없기
			 * 때문이다.  더구나 mark가 이미 거기 있을 수 있으므로 프레임 시작
			 * 이전의 행을 가져오려 하는 것은 안전하지 않아, 여기서는 실제로
			 * frameheadpos와 대조해 확인해야 한다.
			 */
			switch (winstate->frameOptions & FRAMEOPTION_EXCLUSION)
			{
				case 0:
					/* 조정이 필요 없음 */
					mark_pos = abs_pos;
					break;
				case FRAMEOPTION_EXCLUDE_CURRENT_ROW:
					if (abs_pos <= winstate->currentpos &&
						winstate->currentpos < winstate->frametailpos)
						abs_pos--;
					update_frameheadpos(winstate);
					if (abs_pos < winstate->frameheadpos)
						goto out_of_frame;
					mark_pos = winstate->frameheadpos;
					break;
				case FRAMEOPTION_EXCLUDE_GROUP:
					update_grouptailpos(winstate);
					if (abs_pos < winstate->grouptailpos &&
						winstate->groupheadpos < winstate->frametailpos)
					{
						int64		overlapend = Min(winstate->grouptailpos,
													 winstate->frametailpos);

						abs_pos -= overlapend - winstate->groupheadpos;
					}
					update_frameheadpos(winstate);
					if (abs_pos < winstate->frameheadpos)
						goto out_of_frame;
					mark_pos = winstate->frameheadpos;
					break;
				case FRAMEOPTION_EXCLUDE_TIES:
					update_grouptailpos(winstate);
					if (abs_pos < winstate->grouptailpos &&
						winstate->groupheadpos < winstate->frametailpos)
					{
						int64		overlapend = Min(winstate->grouptailpos,
													 winstate->frametailpos);

						if (abs_pos == overlapend - 1)
							abs_pos = winstate->currentpos;
						else
							abs_pos -= overlapend - 1 - winstate->groupheadpos;
					}
					update_frameheadpos(winstate);
					if (abs_pos < winstate->frameheadpos)
						goto out_of_frame;
					mark_pos = winstate->frameheadpos;
					break;
				default:
					elog(ERROR, "unrecognized frame option state: 0x%x",
						 winstate->frameOptions);
					mark_pos = 0;	/* 컴파일러 경고를 막기 위함 */
					break;
			}

			num_reduced_frame = row_is_in_reduced_frame(winobj,
														winstate->frameheadpos);
			/*
			 * 0 은 RPR 이 아닌 윈도우를 뜻하며, 이런 윈도우에는 축소된
			 * 프레임이 없다
			 */
			if (num_reduced_frame < 0)
				goto out_of_frame;
			else if (num_reduced_frame > 0)
			{
				if (-relpos >= num_reduced_frame)
					goto out_of_frame;
				abs_pos = winstate->frameheadpos + relpos +
					num_reduced_frame - 1;
			}
			break;
		default:
			elog(ERROR, "unrecognized window seek type: %d", seektype);
			abs_pos = mark_pos = 0; /* 컴파일러 경고를 막기 위함 */
			break;
	}

	if (!window_gettupleslot(winobj, abs_pos, slot))
		goto out_of_frame;

	/* 위 코드가 프레임 밖의 모든 경우를 감지하지는 못하므로 확인한다 */
	if (row_is_in_frame(winobj, abs_pos, slot, false) <= 0)
		goto out_of_frame;

	if (isout)
		*isout = false;
	if (set_mark)
	{
		/*
		 * RPR 이 활성화되어 있고 seek 종류가 WINDOW_SEEK_TAIL 이면, mark
		 * 위치를 무조건 frameheadpos로 설정한다. 이 경우 프레임은 항상
		 * CURRENT_ROW 에서 시작하고 결코 뒤로 가지 않으므로, 이 위치에 mark를
		 * 설정해도 안전하다.
		 */
		if (winstate->rpPattern != NULL && seektype == WINDOW_SEEK_TAIL)
			mark_pos = winstate->frameheadpos;
		WinSetMarkPosition(winobj, mark_pos);
	}
	return 0;

out_of_frame:
	if (isout)
		*isout = true;
	*isnull = true;
	return -1;
}


/***********************************************************************
 * API exposed to window functions
 ***********************************************************************/


/*
 * WinCheckAndInitializeNullTreatment
 *		Check null treatment clause and sets ignore_nulls
 *
 * Window functions should call this to check if they are being called with
 * a null treatment clause when they don't allow it, or to set ignore_nulls.
 */
void
WinCheckAndInitializeNullTreatment(WindowObject winobj,
								   bool allowNullTreatment,
								   FunctionCallInfo fcinfo)
{
	Assert(WindowObjectIsValid(winobj));
	if (winobj->ignore_nulls != NO_NULLTREATMENT && !allowNullTreatment)
	{
		const char *funcname = get_func_name(fcinfo->flinfo->fn_oid);

		if (!funcname)
			elog(ERROR, "could not get function name");
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("function %s does not allow RESPECT/IGNORE NULLS",
						funcname)));
	}
	else if (winobj->ignore_nulls == PARSER_IGNORE_NULLS)
		winobj->ignore_nulls = IGNORE_NULLS;
}

/*
 * WinGetPartitionLocalMemory
 *		Get working memory that lives till end of partition processing
 *
 * On first call within a given partition, this allocates and zeroes the
 * requested amount of space.  Subsequent calls just return the same chunk.
 *
 * Memory obtained this way is normally used to hold state that should be
 * automatically reset for each new partition.  If a window function wants
 * to hold state across the whole query, fcinfo->fn_extra can be used in the
 * usual way for that.
 */
void *
WinGetPartitionLocalMemory(WindowObject winobj, Size sz)
{
	Assert(WindowObjectIsValid(winobj));
	if (winobj->localmem == NULL)
		winobj->localmem =
			MemoryContextAllocZero(winobj->winstate->partcontext, sz);
	return winobj->localmem;
}

/*
 * WinGetCurrentPosition
 *		Return the current row's position (counting from 0) within the current
 *		partition.
 */
int64
WinGetCurrentPosition(WindowObject winobj)
{
	Assert(WindowObjectIsValid(winobj));
	return winobj->winstate->currentpos;
}

/*
 * WinGetPartitionRowCount
 *		Return total number of rows contained in the current partition.
 *
 * Note: this is a relatively expensive operation because it forces the
 * whole partition to be "spooled" into the tuplestore at once.  Once
 * executed, however, additional calls within the same partition are cheap.
 */
int64
WinGetPartitionRowCount(WindowObject winobj)
{
	Assert(WindowObjectIsValid(winobj));
	spool_tuples(winobj->winstate, -1);
	return winobj->winstate->spooled_rows;
}

/*
 * WinSetMarkPosition
 *		Set the "mark" position for the window object, which is the oldest row
 *		number (counting from 0) it is allowed to fetch during all subsequent
 *		operations within the current partition.
 *
 * Window functions do not have to call this, but are encouraged to move the
 * mark forward when possible to keep the tuplestore size down and prevent
 * having to spill rows to disk.
 */
void
WinSetMarkPosition(WindowObject winobj, int64 markpos)
{
	WindowAggState *winstate;

	Assert(WindowObjectIsValid(winobj));
	winstate = winobj->winstate;

	if (markpos < winobj->markpos)
		elog(ERROR, "cannot move WindowObject's mark position backward");
	tuplestore_select_read_pointer(winstate->buffer, winobj->markptr);
	if (markpos > winobj->markpos)
	{
		tuplestore_skiptuples(winstate->buffer,
							  markpos - winobj->markpos,
							  true);
		winobj->markpos = markpos;
	}
	tuplestore_select_read_pointer(winstate->buffer, winobj->readptr);
	if (markpos > winobj->seekpos)
	{
		tuplestore_skiptuples(winstate->buffer,
							  markpos - winobj->seekpos,
							  true);
		winobj->seekpos = markpos;
	}
}

/*
 * WinRowsArePeers
 *		Compare two rows (specified by absolute position in partition) to see
 *		if they are equal according to the ORDER BY clause.
 *
 * NB: this does not consider the window frame mode.
 */
bool
WinRowsArePeers(WindowObject winobj, int64 pos1, int64 pos2)
{
	WindowAggState *winstate;
	WindowAgg  *node;
	TupleTableSlot *slot1;
	TupleTableSlot *slot2;
	bool		res;

	Assert(WindowObjectIsValid(winobj));
	winstate = winobj->winstate;
	node = (WindowAgg *) winstate->ss.ps.plan;

	/* If no ORDER BY, all rows are peers; don't bother to fetch them */
	if (node->ordNumCols == 0)
		return true;

	/*
	 * Note: OK to use temp_slot_2 here because we aren't calling any
	 * frame-related functions (those tend to clobber temp_slot_2).
	 */
	slot1 = winstate->temp_slot_1;
	slot2 = winstate->temp_slot_2;

	if (!window_gettupleslot(winobj, pos1, slot1))
		elog(ERROR, "specified position is out of window: " INT64_FORMAT,
			 pos1);
	if (!window_gettupleslot(winobj, pos2, slot2))
		elog(ERROR, "specified position is out of window: " INT64_FORMAT,
			 pos2);

	res = are_peers(winstate, slot1, slot2);

	ExecClearTuple(slot1);
	ExecClearTuple(slot2);

	return res;
}

/*
 * WinGetFuncArgInPartition
 *		Evaluate a window function's argument expression on a specified
 *		row of the partition.  The row is identified in lseek(2) style,
 *		i.e. relative to the current, first, or last row.
 *
 * argno: argument number to evaluate (counted from 0)
 * relpos: signed rowcount offset from the seek position
 * seektype: WINDOW_SEEK_CURRENT, WINDOW_SEEK_HEAD, or WINDOW_SEEK_TAIL
 * set_mark: If the row is found and set_mark is true, the mark is moved to
 *		the row as a side-effect.
 * isnull: output argument, receives isnull status of result
 * isout: output argument, set to indicate whether target row position
 *		is out of partition (can pass NULL if caller doesn't care about this)
 *
 * Specifying a nonexistent row is not an error, it just causes a null result
 * (plus setting *isout true, if isout isn't NULL).
 */
Datum
WinGetFuncArgInPartition(WindowObject winobj, int argno,
						 int relpos, int seektype, bool set_mark,
						 bool *isnull, bool *isout)
{
	WindowAggState *winstate;
	int64		abs_pos;
	int64		mark_pos;
	Datum		datum;
	bool		null_treatment;
	int			notnull_offset;
	int			notnull_relpos;
	int			forward;
	bool		myisout;
	bool		got_datum;

	Assert(WindowObjectIsValid(winobj));
	winstate = winobj->winstate;

	null_treatment = (winobj->ignore_nulls == IGNORE_NULLS && relpos != 0);

	switch (seektype)
	{
		case WINDOW_SEEK_CURRENT:
			if (null_treatment)
				abs_pos = winstate->currentpos;
			else
				abs_pos = winstate->currentpos + relpos;
			break;
		case WINDOW_SEEK_HEAD:
			if (null_treatment)
				abs_pos = 0;
			else
				abs_pos = relpos;
			break;
		case WINDOW_SEEK_TAIL:
			spool_tuples(winstate, -1);
			abs_pos = winstate->spooled_rows - 1 + relpos;
			break;
		default:
			elog(ERROR, "unrecognized window seek type: %d", seektype);
			abs_pos = 0;		/* keep compiler quiet */
			break;
	}

	/* Easy case if IGNORE NULLS is not specified */
	if (!null_treatment)
	{
		/* get tuple and evaluate in partition */
		datum = gettuple_eval_partition(winobj, argno,
										abs_pos, isnull, &myisout);
		if (!myisout && set_mark)
			WinSetMarkPosition(winobj, abs_pos);
		if (isout)
			*isout = myisout;
		return datum;
	}

	/* Prepare for loop */
	notnull_offset = 0;
	notnull_relpos = abs(relpos);
	forward = relpos > 0 ? 1 : -1;
	myisout = false;
	got_datum = false;
	datum = 0;

	/*
	 * IGNORE NULLS + WINDOW_SEEK_CURRENT + relpos > 0 case, we would fetch
	 * beyond the current row + relpos to find out the target row. If we mark
	 * at abs_pos, next call to WinGetFuncArgInPartition or
	 * WinGetFuncArgInFrame (in case when a window function have multiple
	 * args) could fail with "cannot fetch row before WindowObject's mark
	 * position". So keep the mark position at currentpos.
	 */
	if (seektype == WINDOW_SEEK_CURRENT && relpos > 0)
		mark_pos = winstate->currentpos;
	else
	{
		/*
		 * For other cases we have no idea what position of row callers would
		 * fetch next time. Also for relpos < 0 case (we go backward), we
		 * cannot set mark either. For those cases we always set mark at 0.
		 */
		mark_pos = 0;
	}

	/*
	 * Get the next nonnull value in the partition, moving forward or backward
	 * until we find a value or reach the partition's end.  We cache the
	 * nullness status because we may repeat this process many times.
	 */
	do
	{
		int			nn_info;	/* NOT NULL status */

		abs_pos += forward;
		if (abs_pos < 0)		/* clearly out of partition */
			break;

		/* check NOT NULL cached info */
		nn_info = get_notnull_info(winobj, abs_pos, argno);
		if (nn_info == NN_NOTNULL)	/* this row is known to be NOT NULL */
			notnull_offset++;
		else if (nn_info == NN_NULL)	/* this row is known to be NULL */
			continue;			/* keep on moving forward or backward */
		else					/* need to check NULL or not */
		{
			/*
			 * NOT NULL info does not exist yet.  Get tuple and evaluate func
			 * arg in partition. Keep the return value in case this row is the
			 * target; re-evaluating a volatile argument could give a
			 * different nullness status.
			 */
			datum = gettuple_eval_partition(winobj, argno,
											abs_pos, isnull, &myisout);
			if (myisout)		/* out of partition? */
				break;
			if (!*isnull)
			{
				notnull_offset++;
				if (notnull_offset >= notnull_relpos)
					got_datum = true;
			}
			/* record the row status */
			put_notnull_info(winobj, abs_pos, argno, *isnull);
		}
	} while (notnull_offset < notnull_relpos);

	/* get tuple and evaluate func arg in partition */
	if (!got_datum)
		datum = gettuple_eval_partition(winobj, argno,
										abs_pos, isnull, &myisout);
	if (!myisout && set_mark)
		WinSetMarkPosition(winobj, mark_pos);
	if (isout)
		*isout = myisout;

	return datum;
}

/*
 * WinGetFuncArgInFrame
 *		Evaluate a window function's argument expression on a specified
 *		row of the window frame.  The row is identified in lseek(2) style,
 *		i.e. relative to the first or last row of the frame.  (We do not
 *		support WINDOW_SEEK_CURRENT here, because it's not very clear what
 *		that should mean if the current row isn't part of the frame.)
 *
 * argno: argument number to evaluate (counted from 0)
 * relpos: signed rowcount offset from the seek position
 * seektype: WINDOW_SEEK_HEAD or WINDOW_SEEK_TAIL
 * set_mark: If the row is found/in frame and set_mark is true, the mark is
 *		moved to the row as a side-effect.
 * isnull: output argument, receives isnull status of result
 * isout: output argument, set to indicate whether target row position
 *		is out of frame (can pass NULL if caller doesn't care about this)
 *
 * Specifying a nonexistent or not-in-frame row is not an error, it just
 * causes a null result (plus setting *isout true, if isout isn't NULL).
 *
 * Note that some exclusion-clause options lead to situations where the
 * rows that are in-frame are not consecutive in the partition.  But we
 * count only in-frame rows when measuring relpos.
 *
 * The set_mark flag is interpreted as meaning that the caller will specify
 * a constant (or, perhaps, monotonically increasing) relpos in successive
 * calls, so that *if there is no exclusion clause* there will be no need
 * to fetch a row before the previously fetched row.  But we do not expect
 * the caller to know how to account for exclusion clauses.  Therefore,
 * if there is an exclusion clause we take responsibility for adjusting the
 * mark request to something that will be safe given the above assumption
 * about relpos.
 */
Datum
WinGetFuncArgInFrame(WindowObject winobj, int argno,
					 int relpos, int seektype, bool set_mark,
					 bool *isnull, bool *isout)
{
	WindowAggState *winstate;
	ExprContext *econtext;
	TupleTableSlot *slot;

	Assert(WindowObjectIsValid(winobj));
	winstate = winobj->winstate;
	econtext = winstate->ss.ps.ps_ExprContext;
	slot = winstate->temp_slot_1;

	if (winobj->ignore_nulls == IGNORE_NULLS)
		return ignorenulls_getfuncarginframe(winobj, argno, relpos, seektype,
											 set_mark, isnull, isout);

	if (WinGetSlotInFrame(winobj, slot,
						  relpos, seektype, set_mark,
						  isnull, isout) == 0)
	{
		econtext->ecxt_outertuple = slot;
		return ExecEvalExpr((ExprState *) list_nth(winobj->argstates, argno),
							econtext, isnull);
	}

	if (isout)
		*isout = true;
	*isnull = true;
	return (Datum) 0;
}

/*
 * WinGetFuncArgCurrent
 *		Evaluate a window function's argument expression on the current row.
 *
 * argno: argument number to evaluate (counted from 0)
 * isnull: output argument, receives isnull status of result
 *
 * Note: this isn't quite equivalent to WinGetFuncArgInPartition or
 * WinGetFuncArgInFrame targeting the current row, because it will succeed
 * even if the WindowObject's mark has been set beyond the current row.
 * This should generally be used for "ordinary" arguments of a window
 * function, such as the offset argument of lead() or lag().
 */
Datum
WinGetFuncArgCurrent(WindowObject winobj, int argno, bool *isnull)
{
	WindowAggState *winstate;
	ExprContext *econtext;

	Assert(WindowObjectIsValid(winobj));
	winstate = winobj->winstate;

	econtext = winstate->ss.ps.ps_ExprContext;

	econtext->ecxt_outertuple = winstate->ss.ss_ScanTupleSlot;
	return ExecEvalExpr((ExprState *) list_nth(winobj->argstates, argno),
						econtext, isnull);
}
