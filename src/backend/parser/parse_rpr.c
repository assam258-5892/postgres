/*-------------------------------------------------------------------------
 *
 * parse_rpr.c
 *	  파서에서 행 패턴 인식(Row Pattern Recognition) 절을 처리한다.
 *
 * 이 파일은 질의 분석 중에 RPR 관련 절을 원시 파스 트리에서
 * 플래너 구조로 변환한다:
 *   - 프레임 옵션을 검증한다 (ROWS 만 가능, CURRENT ROW 에서 시작해야 하고,
 *     EXCLUDE 는 불가능하며, CURRENT ROW 는 프레임 끝으로 허용되지 않는다)
 *   - PATTERN 변수 개수를 검증한다 (최대 RPR_VARID_MAX + 1)
 *   - DEFINE 절을 변환한다
 *   - PATTERN 파스 트리와 AFTER MATCH SKIP TO 플래그를 저장한다
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
#include "optimizer/rpr.h"
#include "parser/parse_clause.h"
#include "parser/parse_rpr.h"

/* DEFINE 절 워커(walker) 컨텍스트 -- 사용법은 define_walker 참고. */
typedef enum
{
	DEFINE_PHASE_BODY,			/* 최상위 DEFINE 표현식 */
	DEFINE_PHASE_NAV_ARG,		/* 외부 nav 의 arg 서브트리 내부 */
	DEFINE_PHASE_NAV_OFFSET,	/* 외부 nav 의 offset_arg /
								 * compound_offset_arg 내부 */
} DefinePhase;

typedef struct
{
	ParseState *pstate;
	DefinePhase phase;
	int			nav_count;		/* 현재 nav.arg 의 RPRNavExpr 노드 수 */
	bool		has_column_ref; /* 현재 nav 스코프에서 Var 발견 */
	RPRNavKind	inner_kind;		/* 현재 arg 의 첫 중첩 nav kind */
} DefineWalkCtx;

/* 전방 선언 */
static void validateRPRPatternVarCount(ParseState *pstate, RPRPatternNode *node,
									   List **varNames);
static List *transformDefineClause(ParseState *pstate, WindowDef *windef);
static bool define_walker(Node *node, void *context);
static bool rpr_frame_is_supported(int frameOptions);

/*
 * transformRPR
 *		행 패턴 인식(Row Pattern Recognition) 관련 절을 처리한다.
 *
 * 파스 트리의 RPR 절을 검증하고 플래너 구조로 변환한다:
 *   - 프레임 옵션을 검증한다 (ROWS 만 가능, CURRENT ROW 에서 시작해야 하고,
 *     EXCLUDE 는 불가능하며, CURRENT ROW 는 프레임 끝으로 허용되지 않는다)
 *   - AFTER MATCH SKIP TO 플래그를 설정한다
 *   - DEFINE 절을 TargetEntry 리스트로 변환한다
 *   - 디파스를 위해 PATTERN 파스 트리를 저장한다
 *     (최적화는 플래너에서 수행된다)
 *
 * windef 에 rpCommonSyntax 가 없으면 (RPR 이 아닌 윈도우) 일찍 반환한다.
 */
void
transformRPR(ParseState *pstate, WindowClause *wc, WindowDef *windef)
{
	/* 윈도우에 행 패턴이 없으면 할 일이 없다 */
	if (windef->rpCommonSyntax == NULL)
		return;

	if (!rpr_frame_is_supported(wc->frameOptions))
	{
		/*
		 * 프레임 타입 키워드의 위치가 윈도우 정의 시작 위치보다 우선한다.
		 * 프레임이 기본값으로 채워졌을 때 가리킬 수 있는 위치는 윈도우 정의의
		 * 시작뿐이기 때문이다.
		 */
		int			location = windef->frameLocation >= 0 ?
			windef->frameLocation : windef->location;

		ereport(ERROR,
				errcode(ERRCODE_WINDOWING_ERROR),
				errmsg("unsupported frame for row pattern recognition"),
		/*- translator: both %s are SQL window frame specifications */
				errdetail("The frame must be \"%s\" or \"%s\".",
						  "ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING",
						  "ROWS BETWEEN CURRENT ROW AND offset FOLLOWING"),
				parser_errposition(pstate, location));
	}

	/*
	 * EXCLUDE 는 프레임 모양의 일부가 아니므로, 그 자체로 별도로 보고하며
	 * 자신의 위치에서 보고한다.
	 */
	if (wc->frameOptions & FRAMEOPTION_EXCLUSION)
	{
		int			location = windef->excludeLocation >= 0 ?
			windef->excludeLocation : windef->location;

		ereport(ERROR,
				errcode(ERRCODE_WINDOWING_ERROR),
				errmsg("cannot use EXCLUDE with row pattern recognition"),
				parser_errposition(pstate, location));
	}

	Assert(wc->frameOptions & FRAMEOPTION_ROWS);

	/* AFTER MATCH SKIP TO 플래그를 대입한다 */
	wc->rpSkipTo = windef->rpCommonSyntax->rpSkipTo;

	/* DEFINE 절을 TargetEntry 리스트로 변환한다 */
	wc->defineClause = transformDefineClause(pstate, windef);

	/* 디파스를 위해 PATTERN 파스 트리를 저장한다 */
	wc->rpPattern = windef->rpCommonSyntax->rpPattern;
}

/*
 * rpr_frame_is_supported
 *		행 패턴 인식이 매칭하는 프레임 모양인가?
 *
 * ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING 과
 * ROWS BETWEEN CURRENT ROW AND offset FOLLOWING 만 지원한다.  EXCLUDE 는
 * 모양의 일부가 아니므로 호출자가 거부한다.
 *
 * offset 값은 실행 시점까지 정해지지 않으며, calculate_frame_offsets() 가
 * 그곳에서 양수가 아닌 값을 거부한다.
 */
static bool
rpr_frame_is_supported(int frameOptions)
{
	if ((frameOptions & FRAMEOPTION_ROWS) == 0)
		return false;
	if ((frameOptions & FRAMEOPTION_START_CURRENT_ROW) == 0)
		return false;
	if ((frameOptions & (FRAMEOPTION_END_UNBOUNDED_FOLLOWING |
						 FRAMEOPTION_END_OFFSET_FOLLOWING)) == 0)
		return false;

	return true;
}

/*
 * validateRPRPatternVarCount
 *		PATTERN 변수 개수가 varId 범위에 들어맞는지 검증한다.
 *
 * 패턴 트리를 재귀적으로 순회하면서 고유한 변수 이름을 수집한다.  고유한 변수
 * 개수가 RPR_VARID_MAX 보다 큰 varId 를 필요로 하면 오류를 발생시킨다.
 *
 * varNames 는 고유한 PATTERN 변수 이름을 수집하며, transformColumnRef 는 이를
 * p_rpr_pattern_vars 를 통해 확인해 패턴 변수 한정자를 식별한다. 이 목록에
 * 대해 DEFINE 변수 이름을 교차 검사하는 일은 한 번만 수행하면 되므로
 * 호출자의 책임이다.
 */
static void
validateRPRPatternVarCount(ParseState *pstate, RPRPatternNode *node,
						   List **varNames)
{
	/* 패턴 노드는 반드시 존재해야 한다 - 파서는 항상 NULL 아닌 루트를 제공 */
	Assert(node != NULL);

	/*
	 * trailing_alt 는 일시적인 문법 플래그다; 패턴이 파싱 분석에 도달하기
	 * 전에 splitRPRTrailingAlt 가 모든 노드에서 이를 지웠어야 한다.
	 */
	Assert(!node->trailing_alt);

	check_stack_depth();

	switch (node->nodeType)
	{
		case RPR_PATTERN_VAR:
			/* 목록에 아직 없으면 변수 이름을 추가한다 */
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
					 * 추가하기 전에 RPR_VARID_MAX 와 비교해 검사한다.  varId
					 * 값은 0 부터 RPR_VARID_MAX 까지(포함) 사용하므로, 다음에
					 * 할당될 varId(현재 목록 길이) 가 이를 넘으면 안 된다.
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
			/* 자식으로 재귀한다 */
			foreach_node(RPRPatternNode, child, node->children)
			{
				validateRPRPatternVarCount(pstate, child, varNames);
			}
			break;
	}
}

/*
 * transformDefineClause
 *		DEFINE 절을 처리하고 ResTarget 을 TargetEntry 리스트로 변환한다.
 *
 * Note: DEFINE 에 없는 변수는 실행기가 TRUE 로 평가한다.  DEFINE 에는 있지만
 * PATTERN 에는 없는 변수는 오류로 거부한다.
 *
 * XXX DEFINE 안의 패턴 변수 수식 표현식(예: "A.price") 은 아직 지원하지
 * 않는다.  현재는 parse_expr.c 의 transformColumnRef 가 p_rpr_pattern_vars
 * 검사를 통해 거부한다.
 */
static List *
transformDefineClause(ParseState *pstate, WindowDef *windef)
{
	List	   *defineClause = NIL;
	List	   *patternVarNames = NIL;

	/*
	 * 문법은 DEFINE 을 포함한 윈도우 명세에 대해서만 RPCommonSyntax 를
	 * 만들므로, 이 목록은 여기서 결코 비어 있지 않다.
	 */
	Assert(windef->rpCommonSyntax->rpDefs != NULL);

	/*
	 * PATTERN 변수 개수를 검증하고, transformColumnRef 를 위해 PATTERN 변수
	 * 이름을 수집한다.
	 */
	validateRPRPatternVarCount(pstate, windef->rpCommonSyntax->rpPattern,
							   &patternVarNames);
	pstate->p_rpr_pattern_vars = patternVarNames;

	/*
	 * DEFINE 스코프를 연다.  DEFINE 조건이 받는 제약은 조건 전체에
	 * 적용되므로, 이 스코프는 p_expr_kind 가 아니라 이것을 기준으로 삼는다.
	 * p_expr_kind 는 가장 안쪽 절의 이름만 담고, 조건 안에 자신만의 kind 를
	 * 가진 무언가가 중첩되면 그 값으로 대체되기 때문이다. 이 스코프는 모든
	 * DEFINE 표현식이 변환된 뒤 아래에서 닫는다.
	 */
	pstate->p_rpr_define = true;

	/*
	 * PATTERN 에 나타나지 않는 이름을 가진 DEFINE 변수는 모두 거부한다. 이
	 * 교차 검사는 한 번만 수행하면 되므로, 재귀 호출되는
	 * validateRPRPatternVarCount() 안이 아니라 호출자인 여기에 둔다.
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
	 * 중복된 행 패턴 정의 변수를 검사한다.  표준은 두 행 패턴 정의 변수
	 * 이름이 서로 같아서는 안 된다고 규정한다.  오류는 나중에 나온(중복된)
	 * 정의 위치에서 보고한다.
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
		 * DEFINE 표현식을 변환하고 boolean 으로 강제 변환한다.  그 결과는
		 * wc->defineClause 에 속하며, 질의 타깃 리스트 전체에는 결코 들어가지
		 * 않는다: 이 안에는 이를 소유한 WindowAgg 만 평가할 수 있는
		 * RPRNavExpr 노드(PREV/NEXT/FIRST/LAST) 가 들어 있을 수
		 * 있기 때문이다.
		 */
		expr = transformWhereClause(pstate, restarget->val,
									EXPR_KIND_RPR_DEFINE, "DEFINE");

		/* 변환된 expr 로부터 곧바로 defineClause 엔트리를 만든다 */
		teDefine = makeTargetEntry((Expr *) expr,
								   list_length(defineClause) + 1,
								   pstrdup(restarget->name),
								   true);

		/* 변환된 DEFINE 절(TargetEntry 리스트) 을 만든다 */
		defineClause = lappend(defineClause, teDefine);
	}
	pstate->p_rpr_define = false;
	pstate->p_rpr_pattern_vars = NIL;

	/*
	 * DEFINE 표현식을 검증한다: 중첩된 PREV/NEXT, 열 참조, 복합 평탄화까지
	 * 변수마다 한 번의 순회로 모두 처리한다.
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

	return defineClause;
}

/*
 * define_walker
 *		DEFINE 절을 한 번의 순회로 검증한다.  각 노드에서 다음을 강제한다:
 *
 *		  [1] 각 외부 RPRNavExpr 에 대해 (PHASE_BODY -> PHASE_NAV_ARG):
 *			  - nav.arg 는 열 참조를 적어도 하나 포함해야 한다
 *			  - FIRST/LAST 를 감싼 PREV/NEXT 는 그 자리에서 복합
 *				kind(PREV_FIRST, PREV_LAST, NEXT_FIRST,
 *				NEXT_LAST) 로 평탄화된다
 *			  - nav.arg 자신이 아닌 내부 탐색은 직접 인수가 아니라는
 *				이유로 거부된다
 *			  - 그 외의 중첩은 모두 거부된다 (FIRST(PREV()), PREV(PREV()),
 *				FIRST(FIRST()), 3 단계 이상)
 *		  [2] 각 nav offset 에 대해 (PHASE_NAV_OFFSET):
 *			  - 런타임 상수여야 한다 (열 참조 불가)
 *			  - 행 패턴 탐색 연산을 포함해서는 안 된다
 *
 * 외부 nav 에 들어가면, 워커는 PHASE_NAV_ARG 에서 nav.arg 를 순회해 중첩과 열
 * 참조 상태를 수집하고, 복합 형태를 평탄화하거나 중첩 오류를 일으킨 뒤,
 * PHASE_NAV_OFFSET 에서 평탄화 후의 offset(들) 을 순회한다.  복합 형태의 내부
 * offset 은 두 패스 모두에서 순회된다: PHASE_NAV_ARG 는 nav.arg 전체가 열
 * 참조를 가지는지만 확인하므로, 내부 offset 이 흘렸을 열 참조를 잡아내기 위해
 * offset 을 다시 순회한다.
 *
 * Var 발견은 감싸는 nav 스코프의 열 참조 규칙에 반영되고, PHASE_NAV_ARG
 * 안에서의 RPRNavExpr 발견은 중첩 판단에 반영된다.  각 phase 자체는
 * DefinePhase 가 선언된 곳에서 설명한다.
 */
static bool
define_walker(Node *node, void *context)
{
	DefineWalkCtx *ctx = (DefineWalkCtx *) context;

	if (node == NULL)
		return false;

	/* Var 발견은 감싸는 nav 스코프의 열 참조 규칙에 반영된다. */
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
			 * 외부 nav.arg 안에 중첩된 nav: 외부의 복합/중첩 판단을 위해
			 * 기록한 뒤, 더 깊은 Var 도 계속 관찰되도록 재귀를 이어간다.
			 */
			if (ctx->nav_count == 0)
				ctx->inner_kind = nav->kind;
			ctx->nav_count++;
			return expression_tree_walker(node, define_walker, ctx);
		}
		else if (ctx->phase == DEFINE_PHASE_NAV_OFFSET)
		{
			/*
			 * 탐색 offset 은 런타임 상수여야 하므로, 탐색 연산을 포함할
			 * 수 없다.
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
			 * PHASE_BODY: 최상위 수준의 외부 nav 다.  먼저 arg 를 순회해
			 * 중첩/열 참조 상태를 수집한 뒤 검증하고, (복합 형태라면)
			 * 평탄화한 다음 offset(들) 을 순회한다.
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

					/* 인수 전체가 아닌 내부 nav 는 거부한다 */
					if (!IsA(nav->arg, RPRNavExpr))
						ereport(ERROR,
								errcode(ERRCODE_SYNTAX_ERROR),
								errmsg("row pattern navigation operation must be a direct argument of the outer navigation"),
								errhint("Only PREV(FIRST()), PREV(LAST()), NEXT(FIRST()), and NEXT(LAST()) compound forms are allowed."),
								parser_errposition(ctx->pstate, nav->location));

					/* 3단계 이상의 중첩은 거부한다; 형제는 위에서 처리됨 */
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
					 * 평탄화된 인수도 아래의 단순 nav 경우와 마찬가지로 열
					 * 참조를 포함해야 한다.
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
			 * 상수 offset 규칙을 강제하기 위해 PHASE_NAV_OFFSET 에서 offset
			 * 인수(들) 를 순회한다.  복합 형태라면
			 * 내부(평탄화 후의 nav->offset_arg) 와 외부(compound_offset_arg)
			 * offset 이 모두 상수여야 한다; 내부의 열 참조 여부는
			 * PHASE_NAV_ARG 순회 중에는 별도로 추적되지 않았으므로
			 * (이 순회는 nav.arg 전체가 Var 를 하나라도 가지는지만 확인한다),
			 * 내부 offset 이 흘렸을 열 참조를 잡아내기 위해 여기서 다시
			 * 순회한다.
			 */
			ctx->phase = DEFINE_PHASE_NAV_OFFSET;

			if (nav->offset_arg != NULL)
			{
				ctx->has_column_ref = false;
				(void) define_walker((Node *) nav->offset_arg, ctx);
				if (ctx->has_column_ref)
					ereport(ERROR,
							errcode(ERRCODE_SYNTAX_ERROR),
							errmsg("row pattern navigation offset must be a run-time constant"),
							parser_errposition(ctx->pstate, exprLocation((Node *) nav->offset_arg)));
			}
			if (flattened && nav->compound_offset_arg != NULL)
			{
				ctx->has_column_ref = false;
				(void) define_walker((Node *) nav->compound_offset_arg, ctx);
				if (ctx->has_column_ref)
					ereport(ERROR,
							errcode(ERRCODE_SYNTAX_ERROR),
							errmsg("row pattern navigation offset must be a run-time constant"),
							parser_errposition(ctx->pstate, exprLocation((Node *) nav->compound_offset_arg)));
			}

			*ctx = saved;
			return false;
		}
	}

	return expression_tree_walker(node, define_walker, ctx);
}
