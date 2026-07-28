/*-------------------------------------------------------------------------
 *
 * parse_rpr.c
 *	  Handle Row Pattern Recognition clauses in parser.
 *
 * This file transforms RPR-related clauses from raw parse tree to planner
 * structures during query analysis:
 *   - Validates frame options (ROWS only, must start at CURRENT ROW, no
 *     EXCLUDE, and CURRENT ROW is not accepted as the frame end)
 *   - Validates PATTERN variable count (max RPR_VARID_MAX + 1)
 *   - Transforms DEFINE clause
 *   - Stores the PATTERN parse tree and the AFTER MATCH SKIP TO flag
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/parser/parse_rpr.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/optimizer.h"
#include "optimizer/rpr.h"
#include "parser/parse_coerce.h"
#include "parser/parse_collate.h"
#include "parser/parse_expr.h"
#include "parser/parse_relation.h"
#include "parser/parse_rpr.h"
#include "parser/parse_target.h"
#include "parser/parsetree.h"

/* DEFINE clause walker context -- see define_walker for usage. */
typedef enum
{
	DEFINE_PHASE_BODY,			/* top-level DEFINE expression */
	DEFINE_PHASE_NAV_ARG,		/* inside an outer nav's arg subtree */
	DEFINE_PHASE_NAV_OFFSET,	/* inside an outer nav's offset_arg /
								 * compound_offset_arg */
} DefinePhase;

typedef struct
{
	ParseState *pstate;
	DefinePhase phase;
	int			nav_count;		/* RPRNavExpr nodes seen in current nav.arg */
	bool		has_column_ref; /* Var seen in current nav scope */
	RPRNavKind	inner_kind;		/* kind of first nested nav in current arg */
} DefineWalkCtx;

/* Forward declarations */
static void validateRPRPatternVarCount(ParseState *pstate, RPRPatternNode *node,
									   List **varNames);
static List *transformDefineClause(ParseState *pstate, WindowDef *windef,
								   List **targetlist);
static bool define_walker(Node *node, void *context);

/*
 * transformRPR
 *		Process Row Pattern Recognition related clauses.
 *
 * Validates and transforms RPR clauses from parse tree to planner structures:
 *   - Validates frame options (ROWS only, must start at CURRENT ROW, no
 *     EXCLUDE, and CURRENT ROW is not accepted as the frame end)
 *   - Set AFTER MATCH SKIP TO flag
 *   - Transforms DEFINE clause into TargetEntry list
 *   - Stores PATTERN parse tree for deparsing (optimization happens in planner)
 *
 * Returns early if windef has no rpCommonSyntax (non-RPR window).
 */
void
transformRPR(ParseState *pstate, WindowClause *wc, WindowDef *windef,
			 List **targetlist)
{
	/* Window definition must exist when called */
	Assert(windef != NULL);

	/*
	 * Row Pattern Common Syntax clause exists?
	 */
	if (windef->rpCommonSyntax == NULL)
		return;

	/* Check Frame options */

	/* Frame type must be "ROW" */
	if (wc->frameOptions & FRAMEOPTION_GROUPS)
		ereport(ERROR,
				errcode(ERRCODE_WINDOWING_ERROR),
				errmsg("cannot use FRAME option GROUPS with row pattern recognition"),
				errhint("Use ROWS instead."),
				parser_errposition(pstate,
								   windef->frameLocation >= 0 ?
								   windef->frameLocation : windef->location));
	if (wc->frameOptions & FRAMEOPTION_RANGE)
		ereport(ERROR,
				errcode(ERRCODE_WINDOWING_ERROR),
				errmsg("cannot use FRAME option RANGE with row pattern recognition"),
				errhint("Use ROWS instead."),
				parser_errposition(pstate,
								   windef->frameLocation >= 0 ?
								   windef->frameLocation : windef->location));

	/* Frame must start at current row */
	if ((wc->frameOptions & FRAMEOPTION_START_CURRENT_ROW) == 0)
	{
		const char *frameType = "ROWS";
		const char *startBound = "unknown";

		/* Determine current start bound */
		if (wc->frameOptions & FRAMEOPTION_START_UNBOUNDED_PRECEDING)
			startBound = "UNBOUNDED PRECEDING";
		else if (wc->frameOptions & FRAMEOPTION_START_OFFSET_PRECEDING)
			startBound = "offset PRECEDING";
		else if (wc->frameOptions & FRAMEOPTION_START_OFFSET_FOLLOWING)
			startBound = "offset FOLLOWING";

		/* At least one valid frame start option should be set */
		Assert((wc->frameOptions & FRAMEOPTION_START_UNBOUNDED_PRECEDING) ||
			   (wc->frameOptions & FRAMEOPTION_START_OFFSET_PRECEDING) ||
			   (wc->frameOptions & FRAMEOPTION_START_OFFSET_FOLLOWING));

		ereport(ERROR,
				errcode(ERRCODE_WINDOWING_ERROR),
				errmsg("FRAME must start at CURRENT ROW when using row pattern recognition"),
				errdetail("Current frame starts with %s.", startBound),
				errhint("Use: %s BETWEEN CURRENT ROW AND ...", frameType),
				parser_errposition(pstate, windef->frameLocation >= 0 ? windef->frameLocation : windef->location));
	}

	/* EXCLUDE options are not permitted */
	if ((wc->frameOptions & FRAMEOPTION_EXCLUSION) != 0)
	{
		const char *excludeType = "EXCLUDE";

		/* Determine which EXCLUDE option was used */
		if (wc->frameOptions & FRAMEOPTION_EXCLUDE_CURRENT_ROW)
			excludeType = "EXCLUDE CURRENT ROW";
		else if (wc->frameOptions & FRAMEOPTION_EXCLUDE_GROUP)
			excludeType = "EXCLUDE GROUP";
		else if (wc->frameOptions & FRAMEOPTION_EXCLUDE_TIES)
			excludeType = "EXCLUDE TIES";

		/* At least one valid exclude option should be set */
		Assert((wc->frameOptions & FRAMEOPTION_EXCLUDE_CURRENT_ROW) ||
			   (wc->frameOptions & FRAMEOPTION_EXCLUDE_GROUP) ||
			   (wc->frameOptions & FRAMEOPTION_EXCLUDE_TIES));

		ereport(ERROR,
				errcode(ERRCODE_WINDOWING_ERROR),
				errmsg("cannot use EXCLUDE options with row pattern recognition"),
				errdetail("Frame definition includes %s.", excludeType),
				errhint("Remove the EXCLUDE clause from the window definition."),
				parser_errposition(pstate, windef->excludeLocation >= 0 ? windef->excludeLocation : windef->location));
	}

	/*
	 * The standard allows only UNBOUNDED FOLLOWING or a positive offset
	 * FOLLOWING as the frame end.  The equivalent 0 FOLLOWING spelling is
	 * caught at runtime in calculate_frame_offsets().
	 */
	if (wc->frameOptions & FRAMEOPTION_END_CURRENT_ROW)
		ereport(ERROR,
				errcode(ERRCODE_WINDOWING_ERROR),
				errmsg("cannot use CURRENT ROW as frame end with row pattern recognition"),
				errhint("Use UNBOUNDED FOLLOWING or a positive offset FOLLOWING."),
				parser_errposition(pstate,
								   windef->frameLocation >= 0 ?
								   windef->frameLocation : windef->location));

	/* Assign AFTER MATCH SKIP TO flag */
	wc->rpSkipTo = windef->rpCommonSyntax->rpSkipTo;

	/* Transform DEFINE clause into list of TargetEntry's */
	wc->defineClause = transformDefineClause(pstate, windef, targetlist);

	/* Store PATTERN parse tree for deparsing */
	wc->rpPattern = windef->rpCommonSyntax->rpPattern;
}

/*
 * validateRPRPatternVarCount
 *		Validate that PATTERN variable count fits the varId range.
 *
 * Recursively traverses the pattern tree, collecting unique variable names.
 * Throws an error if the number of unique variables would require a varId
 * greater than RPR_VARID_MAX.
 *
 * varNames collects the unique PATTERN variable names, which is what
 * transformColumnRef checks via p_rpr_pattern_vars to identify pattern
 * variable qualifiers.  Cross-checking DEFINE variable names against this
 * list is the caller's responsibility, since it only needs to run once.
 */
static void
validateRPRPatternVarCount(ParseState *pstate, RPRPatternNode *node,
						   List **varNames)
{
	/* Pattern node must exist - parser always provides non-NULL root */
	Assert(node != NULL);

	/*
	 * trailing_alt is a transient grammar flag; splitRPRTrailingAlt must have
	 * cleared it on every node before the pattern reaches parse analysis.
	 */
	Assert(!node->trailing_alt);

	check_stack_depth();

	switch (node->nodeType)
	{
		case RPR_PATTERN_VAR:
			/* Add variable name if not already in list */
			{
				bool		found = false;

				foreach_node(String, varname, *varNames)
				{
					if (strcmp(strVal(varname), node->varName) == 0)
					{
						found = true;
						break;
					}
				}
				if (!found)
				{
					/*
					 * Check against RPR_VARID_MAX before adding.  varId
					 * values run 0 to RPR_VARID_MAX inclusive, so the next
					 * varId to be assigned (the current list length) must not
					 * exceed it.
					 */
					if (list_length(*varNames) > RPR_VARID_MAX)
						ereport(ERROR,
								errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
								errmsg("too many row pattern variables"),
								errdetail("The maximum number of row pattern variables is %d.", RPR_VARID_MAX + 1),
								parser_errposition(pstate,
												   exprLocation((Node *) node)));

					*varNames = lappend(*varNames, makeString(pstrdup(node->varName)));
				}
			}
			break;

		case RPR_PATTERN_SEQ:
		case RPR_PATTERN_ALT:
		case RPR_PATTERN_GROUP:
			/* Recurse into children */
			foreach_node(RPRPatternNode, child, node->children)
			{
				validateRPRPatternVarCount(pstate, child, varNames);
			}
			break;
	}
}

/* State for ensure_define_inputs_walker. */
typedef struct EnsureDefineInputsCtx
{
	ParseState *pstate;
	List	  **targetlist;
} EnsureDefineInputsCtx;

static bool
ensure_define_inputs_walker(Node *node, EnsureDefineInputsCtx *ctx)
{
	if (node == NULL)
		return false;

	/*
	 * A subexpression that a sort/group clause already computes needs nothing
	 * of its own.  Its targetlist entry survives into the WindowAgg's input,
	 * because make_window_input_target() passes an entry bearing a
	 * sortgroupref through untouched, and setrefs.c matches a complex
	 * expression against that input before it descends to Vars.  Stopping
	 * here is what lets a DEFINE clause repeat a GROUP BY expression: taking
	 * the expression apart would offer the grouping logic a column that
	 * grouping does not make available on its own.
	 */
	if (!IsA(node, Var))
	{
		Node	   *stripped = strip_implicit_coercions(node);

		foreach_node(TargetEntry, tle, *ctx->targetlist)
		{
			if (tle->ressortgroupref == 0)
				continue;
			if (equal(strip_implicit_coercions((Node *) tle->expr), stripped))
				return false;
		}
	}

	if (IsA(node, Var))
	{
		Var		   *var = (Var *) node;

		foreach_node(TargetEntry, tle, *ctx->targetlist)
		{
			if (equal(tle->expr, var))
				return false;
		}

		*ctx->targetlist =
			lappend(*ctx->targetlist,
					makeTargetEntry((Expr *) copyObject(var),
									(AttrNumber) ctx->pstate->p_next_resno++,
									NULL,
									true));
		return false;
	}

	return expression_tree_walker(node, ensure_define_inputs_walker, ctx);
}

/*
 * ensure_define_inputs -
 *		Make sure the targetlist carries what a DEFINE expression reads.
 *
 * The whole expression cannot go in the targetlist, since it may contain
 * RPRNavExpr nodes that only the owning WindowAgg can evaluate.  So walk it,
 * leave alone any part a sort/group clause already computes, and add a
 * resjunk entry for every Var that is not covered.
 */
static void
ensure_define_inputs(ParseState *pstate, Node *expr, List **targetlist)
{
	EnsureDefineInputsCtx ctx;

	ctx.pstate = pstate;
	ctx.targetlist = targetlist;
	(void) ensure_define_inputs_walker(expr, &ctx);
}

/*
 * transformDefineClause
 *		Process DEFINE clause and transform ResTarget into list of TargetEntry.
 *
 * Note: Variables not in DEFINE are evaluated as TRUE by the executor.
 * Variables in DEFINE but not in PATTERN are rejected as an error.
 *
 * XXX Pattern variable qualified expressions in DEFINE (e.g. "A.price")
 * are not yet supported.  Currently rejected by transformColumnRef in
 * parse_expr.c via the p_rpr_pattern_vars check.
 */
static List *
transformDefineClause(ParseState *pstate, WindowDef *windef,
					  List **targetlist)
{
	List	   *defineClause = NIL;
	List	   *patternVarNames = NIL;

	/*
	 * The grammar builds an RPCommonSyntax only for a window specification
	 * that carries DEFINE, so the list is never empty here.
	 */
	Assert(windef->rpCommonSyntax->rpDefs != NULL);

	/*
	 * Validate PATTERN variable count and collect the PATTERN variable names
	 * for transformColumnRef.
	 */
	validateRPRPatternVarCount(pstate, windef->rpCommonSyntax->rpPattern,
							   &patternVarNames);
	pstate->p_rpr_pattern_vars = patternVarNames;

	/*
	 * Reject any DEFINE variable whose name does not appear in PATTERN.  This
	 * cross-check only needs to run once, so it lives here in the caller
	 * rather than in the recursive validateRPRPatternVarCount().
	 */
	foreach_node(ResTarget, rt, windef->rpCommonSyntax->rpDefs)
	{
		bool		found = false;

		foreach_node(String, varname, patternVarNames)
		{
			if (strcmp(strVal(varname), rt->name) == 0)
			{
				found = true;
				break;
			}
		}
		if (!found)
			ereport(ERROR,
					errcode(ERRCODE_SYNTAX_ERROR),
					errmsg("DEFINE variable \"%s\" is not used in PATTERN",
						   rt->name),
					parser_errposition(pstate, rt->location));
	}

	/*
	 * Check for duplicate row pattern definition variables.  The standard
	 * requires that no two row pattern definition variable names shall be
	 * equivalent.  Report the error at the later (duplicate) definition.
	 */
	foreach_node(ResTarget, restarget, windef->rpCommonSyntax->rpDefs)
	{
		foreach_node(ResTarget, prior, windef->rpCommonSyntax->rpDefs)
		{
			if (prior == restarget)
				break;
			if (strcmp(prior->name, restarget->name) == 0)
				ereport(ERROR,
						errcode(ERRCODE_SYNTAX_ERROR),
						errmsg("DEFINE variable \"%s\" appears more than once",
							   restarget->name),
						parser_errposition(pstate,
										   exprLocation((Node *) restarget)));
		}
	}

	foreach_node(ResTarget, restarget, windef->rpCommonSyntax->rpDefs)
	{
		TargetEntry *teDefine;
		Node	   *expr;

		/*
		 * Transform the DEFINE expression and coerce it to boolean.  We must
		 * NOT add the whole expression to the query targetlist, because it
		 * may contain RPRNavExpr nodes (PREV/NEXT/FIRST/LAST) that can only
		 * be evaluated inside the owning WindowAgg.  Coercing here, before
		 * the targetlist walk, keeps that walk operating on the final
		 * expression form and surfaces a type mismatch before the targetlist
		 * is touched.
		 */
		expr = transformExpr(pstate, restarget->val,
							 EXPR_KIND_RPR_DEFINE);
		expr = coerce_to_boolean(pstate, expr, "DEFINE");

		/* Build the defineClause entry directly from the transformed expr */
		teDefine = makeTargetEntry((Expr *) expr,
								   list_length(defineClause) + 1,
								   pstrdup(restarget->name),
								   true);

		/* build transformed DEFINE clause (list of TargetEntry) */
		defineClause = lappend(defineClause, teDefine);

		/*
		 * Ensure the targetlist carries what this expression reads, so that
		 * the planner propagates it through the plan tree and it is there for
		 * the WindowAgg's DEFINE evaluation.
		 */
		ensure_define_inputs(pstate, expr, targetlist);
	}
	pstate->p_rpr_pattern_vars = NIL;

	/*
	 * Validate DEFINE expressions: nested PREV/NEXT, column references,
	 * compound flatten -- all in a single walk per variable.
	 */
	foreach_ptr(TargetEntry, te, defineClause)
	{
		DefineWalkCtx ctx;

		ctx.pstate = pstate;
		ctx.phase = DEFINE_PHASE_BODY;
		ctx.nav_count = 0;
		ctx.has_column_ref = false;
		ctx.inner_kind = 0;
		(void) define_walker((Node *) te->expr, &ctx);
	}

	/* mark column origins */
	markTargetListOrigins(pstate, defineClause);

	/* mark all nodes in the DEFINE clause tree with collation information */
	assign_expr_collations(pstate, (Node *) defineClause);

	return defineClause;
}

/*
 * define_walker
 *		Single-pass DEFINE clause validator.  At each node, enforces:
 *
 *		  [1] for each outer RPRNavExpr (PHASE_BODY -> PHASE_NAV_ARG):
 *			  - nav.arg must contain at least one column reference
 *			  - PREV/NEXT wrapping FIRST/LAST is flattened in place
 *				to a compound kind (PREV_FIRST, PREV_LAST, NEXT_FIRST,
 *				NEXT_LAST)
 *			  - an inner navigation that is not nav.arg itself is
 *				rejected as not being a direct argument
 *			  - any other nesting is rejected (FIRST(PREV()),
 *				PREV(PREV()), FIRST(FIRST()), three-or-more deep)
 *		  [2] for each nav offset (PHASE_NAV_OFFSET):
 *			  - must be a run-time constant (no column references)
 *			  - must not contain a row pattern navigation operation
 *
 * Entering an outer nav, the walker walks nav.arg in PHASE_NAV_ARG to collect
 * nesting and column-ref state, flattens a compound form or raises a nesting
 * error, then walks the post-flatten offset(s) in PHASE_NAV_OFFSET.  A
 * compound form's inner offset is walked in both passes: PHASE_NAV_ARG only
 * asks whether nav.arg as a whole holds a column reference, so the offset is
 * walked again to catch one it would have leaked.
 *
 * Var sightings feed the column-ref rule for the enclosing nav scope;
 * RPRNavExpr sightings inside PHASE_NAV_ARG feed the nesting decision.
 * The phases themselves are described where DefinePhase is declared.
 */
static bool
define_walker(Node *node, void *context)
{
	DefineWalkCtx *ctx = (DefineWalkCtx *) context;

	if (node == NULL)
		return false;

	/* Var sighting feeds the column-ref rule for the enclosing nav scope. */
	if (IsA(node, Var) &&
		(ctx->phase == DEFINE_PHASE_NAV_ARG ||
		 ctx->phase == DEFINE_PHASE_NAV_OFFSET))
		ctx->has_column_ref = true;

	if (IsA(node, RPRNavExpr))
	{
		RPRNavExpr *nav = (RPRNavExpr *) node;

		if (ctx->phase == DEFINE_PHASE_NAV_ARG)
		{
			/*
			 * Nested nav inside an outer nav.arg: record for the outer's
			 * compound / nesting decision, then keep recursing so deeper Vars
			 * are still observed.
			 */
			if (ctx->nav_count == 0)
				ctx->inner_kind = nav->kind;
			ctx->nav_count++;
			return expression_tree_walker(node, define_walker, ctx);
		}
		else if (ctx->phase == DEFINE_PHASE_NAV_OFFSET)
		{
			/*
			 * A navigation offset must be a run-time constant, so it cannot
			 * contain a navigation operation.
			 */
			ereport(ERROR,
					errcode(ERRCODE_SYNTAX_ERROR),
					errmsg("row pattern navigation offset cannot contain a row pattern navigation operation"),
					errdetail("A navigation offset must be a run-time constant."),
					parser_errposition(ctx->pstate, nav->location));
		}
		else
		{
			/*
			 * PHASE_BODY: this is an outer nav at top level.  Walk arg first
			 * to collect nesting / column-ref state, then validate and (for
			 * compound forms) flatten, then walk offset(s).
			 */
			DefineWalkCtx saved = *ctx;
			bool		outer_phys = (nav->kind == RPR_NAV_PREV ||
									  nav->kind == RPR_NAV_NEXT);
			bool		flattened = false;

			ctx->phase = DEFINE_PHASE_NAV_ARG;
			ctx->nav_count = 0;
			ctx->has_column_ref = false;
			ctx->inner_kind = 0;
			(void) define_walker((Node *) nav->arg, ctx);

			if (ctx->nav_count > 0)
			{
				bool		inner_phys = (ctx->inner_kind == RPR_NAV_PREV ||
										  ctx->inner_kind == RPR_NAV_NEXT);

				if (outer_phys && !inner_phys)
				{
					RPRNavExpr *inner;

					/* Reject an inner nav that is not the whole argument */
					if (!IsA(nav->arg, RPRNavExpr))
						ereport(ERROR,
								errcode(ERRCODE_SYNTAX_ERROR),
								errmsg("row pattern navigation operation must be a direct argument of the outer navigation"),
								errhint("Only PREV(FIRST()), PREV(LAST()), NEXT(FIRST()), and NEXT(LAST()) compound forms are allowed."),
								parser_errposition(ctx->pstate, nav->location));

					/* Reject triple-or-deeper nesting; siblings caught above */
					if (ctx->nav_count > 1)
						ereport(ERROR,
								errcode(ERRCODE_SYNTAX_ERROR),
								errmsg("cannot nest row pattern navigation more than two levels deep"),
								errhint("Only PREV(FIRST()), PREV(LAST()), NEXT(FIRST()), and NEXT(LAST()) compound forms are allowed."),
								parser_errposition(ctx->pstate, nav->location));

					inner = (RPRNavExpr *) nav->arg;

					if (nav->kind == RPR_NAV_PREV && inner->kind == RPR_NAV_FIRST)
						nav->kind = RPR_NAV_PREV_FIRST;
					else if (nav->kind == RPR_NAV_PREV && inner->kind == RPR_NAV_LAST)
						nav->kind = RPR_NAV_PREV_LAST;
					else if (nav->kind == RPR_NAV_NEXT && inner->kind == RPR_NAV_FIRST)
						nav->kind = RPR_NAV_NEXT_FIRST;
					else if (nav->kind == RPR_NAV_NEXT && inner->kind == RPR_NAV_LAST)
						nav->kind = RPR_NAV_NEXT_LAST;

					nav->compound_offset_arg = nav->offset_arg;
					nav->offset_arg = inner->offset_arg;
					nav->arg = inner->arg;
					flattened = true;

					/*
					 * The flattened argument must include a column reference,
					 * just like the simple-nav case below.
					 */
					if (!ctx->has_column_ref)
						ereport(ERROR,
								errcode(ERRCODE_SYNTAX_ERROR),
								errmsg("argument of row pattern navigation operation must include at least one column reference"),
								parser_errposition(ctx->pstate, nav->location));
				}
				else if (!outer_phys && inner_phys)
					ereport(ERROR,
							errcode(ERRCODE_SYNTAX_ERROR),
							errmsg("FIRST and LAST cannot contain PREV or NEXT"),
							errhint("Only PREV(FIRST()), PREV(LAST()), NEXT(FIRST()), and NEXT(LAST()) compound forms are allowed."),
							parser_errposition(ctx->pstate, nav->location));
				else if (outer_phys && inner_phys)
					ereport(ERROR,
							errcode(ERRCODE_SYNTAX_ERROR),
							errmsg("PREV and NEXT cannot contain PREV or NEXT"),
							errhint("Only PREV(FIRST()), PREV(LAST()), NEXT(FIRST()), and NEXT(LAST()) compound forms are allowed."),
							parser_errposition(ctx->pstate, nav->location));
				else
					ereport(ERROR,
							errcode(ERRCODE_SYNTAX_ERROR),
							errmsg("FIRST and LAST cannot contain FIRST or LAST"),
							errhint("Only PREV(FIRST()), PREV(LAST()), NEXT(FIRST()), and NEXT(LAST()) compound forms are allowed."),
							parser_errposition(ctx->pstate, nav->location));
			}
			else if (!ctx->has_column_ref)
			{
				ereport(ERROR,
						errcode(ERRCODE_SYNTAX_ERROR),
						errmsg("argument of row pattern navigation operation must include at least one column reference"),
						parser_errposition(ctx->pstate, nav->location));
			}

			/*
			 * Walk offset arg(s) in PHASE_NAV_OFFSET to enforce the
			 * constant-offset rule.  For compound forms, both the inner
			 * (post-flatten nav->offset_arg) and outer (compound_offset_arg)
			 * offsets must be constants; the inner's column-ref status was
			 * not separately tracked during the PHASE_NAV_ARG walk (which
			 * only checks that nav.arg as a whole has at least one Var), so
			 * it is re-walked here to catch column references the inner
			 * offset would have leaked.
			 */
			ctx->phase = DEFINE_PHASE_NAV_OFFSET;

			if (nav->offset_arg != NULL)
			{
				ctx->has_column_ref = false;
				(void) define_walker((Node *) nav->offset_arg, ctx);
				if (ctx->has_column_ref)
					ereport(ERROR,
							errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("row pattern navigation offset must be a run-time constant"),
							parser_errposition(ctx->pstate, exprLocation((Node *) nav->offset_arg)));
			}
			if (flattened && nav->compound_offset_arg != NULL)
			{
				ctx->has_column_ref = false;
				(void) define_walker((Node *) nav->compound_offset_arg, ctx);
				if (ctx->has_column_ref)
					ereport(ERROR,
							errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("row pattern navigation offset must be a run-time constant"),
							parser_errposition(ctx->pstate, exprLocation((Node *) nav->compound_offset_arg)));
			}

			*ctx = saved;
			return false;
		}
	}

	return expression_tree_walker(node, define_walker, ctx);
}

/*
 * checkRPRDefineGrouping -
 *	  Refuse the row pattern DEFINE clauses that grouping cannot serve yet.
 *
 * A DEFINE clause is the only part of a WindowClause holding an expression
 * tree of its own: partitionClause and orderClause carry just a sortgroupref
 * into the target list, and the frame offsets are checked to be Var-free.
 * substitute_grouped_columns() therefore never reaches wc->defineClause, and
 * its Vars stay plain relation Vars while the target list copies of the same
 * columns become Vars of the RTE_GROUP RTE.  One shape makes that divergence
 * reach the user, and it is refused here: a grouping column that is not part
 * of every grouping set can be nulled by the grouping step, the target list
 * copy records that in varnullingrels and the DEFINE copy does not, and
 * setrefs.c would later notice.
 *
 * Called from parseCheckAggregates() before it substitutes the target list,
 * with that function's own working state: groupClauses is the TargetEntry list
 * for the acceptable GROUP BY expressions with join aliases flattened, and
 * gset_common holds the ressortgroupref values present in every grouping set.
 *
 * XXX This whole function is a stopgap and should be deleted once the DEFINE
 * clause takes part in grouping.  That needs three things: a third
 * substitute_grouped_columns() call over wc->defineClause, a matching
 * flatten_group_exprs() over it in subquery_planner(), and the same in
 * get_query_def() so that a view over grouped input still deparses.
 *
 * XXX Checking during parse analysis over-rejects a DEFINE clause whose only
 * reference to the column is dead code, as in "true OR c IS NOT NULL": the
 * planner folds that Var away and nothing would have broken.  Moving the
 * check next to the volatility check in subquery_planner() would fix that,
 * but CREATE VIEW does not plan, so it would leave behind a view that cannot
 * be selected from.
 */
void
checkRPRDefineGrouping(ParseState *pstate, Query *qry,
					   List *groupClauses, List *gset_common,
					   bool hasJoinRTEs)
{
	ListCell   *lc;

	/*
	 * Without an RTE_GROUP RTE nothing is substituted, so the two copies
	 * cannot diverge.  This is what lets GROUP BY () through.
	 */
	if (!qry->hasGroupRTE)
		return;

	foreach(lc, qry->windowClause)
	{
		WindowClause *wc = (WindowClause *) lfirst(lc);
		Node	   *defineClause;
		List	   *vars;
		ListCell   *lv;

		if (wc->rpPattern == NULL || wc->defineClause == NIL)
			continue;

		/* groupClauses has been flattened already; match that here */
		defineClause = (Node *) wc->defineClause;
		if (hasJoinRTEs)
			defineClause = flatten_join_alias_for_parser(qry, defineClause, 0);

		/*
		 * flags == 0 is safe: a DEFINE clause rejects aggregates, window
		 * functions and subqueries at parse time, and no PlaceHolderVar
		 * exists yet.
		 */
		vars = pull_var_clause(defineClause, 0);

		foreach(lv, vars)
		{
			Var		   *var = (Var *) lfirst(lv);
			TargetEntry *gtle = NULL;
			RangeTblEntry *rte;
			char	   *attname;
			ListCell   *lg;

			/* an outer reference cannot occur: parse_expr.c rejects it */
			Assert(var->varlevelsup == 0);

			foreach(lg, groupClauses)
			{
				TargetEntry *tle = (TargetEntry *) lfirst(lg);

				if (IsA(tle->expr, Var) && equal(tle->expr, var))
				{
					gtle = tle;
					break;
				}
			}

			/*
			 * A column that is not a grouping column of its own is either
			 * covered by a grouping expression the DEFINE clause named as a
			 * whole, or not grouped at all.  substitute_grouped_columns()
			 * reports the second, and correctly.
			 */
			if (gtle == NULL)
				continue;

			/* a grouping column is nullable only under grouping sets */
			if (!qry->groupingSets ||
				list_member_int(gset_common, gtle->ressortgroupref))
				continue;

			rte = rt_fetch(var->varno, qry->rtable);
			attname = get_rte_attribute_name(rte, var->varattno);
			ereport(ERROR,
					errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					errmsg("cannot use column \"%s.%s\" in a DEFINE clause with grouping sets",
						   rte->eref->aliasname, attname),
					errdetail("ROLLUP, CUBE and GROUPING SETS can set this column to null, which a DEFINE clause cannot represent."),
					parser_errposition(pstate, var->location));
		}
	}
}
