/*-------------------------------------------------------------------------
 *
 * execRPR.c
 *	  윈도우 함수를 위한 NFA 기반 행 패턴 인식(RPR) 엔진.
 *
 * 이 파일은 ROWS BETWEEN PATTERN 절(SQL 표준 기능 R020: 윈도우 함수의 행 패턴
 * 인식)을 위한 NFA 실행 엔진을 구현한다.
 *
 * 이 엔진은 컴파일된 RPRPattern 구조체를 직접 실행하여 정규 표현식 컴파일
 * 오버헤드를 피한다.  nodeWindowAgg.c가 이 엔진을 호출하며,
 * executor/execRPR.h에 선언된 인터페이스를 노출한다.
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * IDENTIFICATION
 *	  src/backend/executor/execRPR.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "common/int.h"
#include "executor/execRPR.h"
#include "executor/executor.h"
#include "miscadmin.h"
#include "optimizer/rpr.h"
#include "utils/memutils.h"

/*
 * 이 파일에 구현된 NFA 엔진의 설계와 실행 모델은
 * src/backend/executor/README.rpr를 참고하라.
 */

/* NFA 사이클 감지를 위한 비트맵 매크로 (bitmapset.c, tidbitmap.c 참고) */
#define WORDNUM(x)	((x) / BITS_PER_BITMAPWORD)
#define BITNUM(x)	((x) % BITS_PER_BITMAPWORD)

/*
 * elemIdx의 방문 비트를 설정하고, 다음 리셋이 nfaVisitedEnds
 * 비트맵 전체가 아니라 건드린 범위만 지우면 되도록
 * high-water 마크(nfaVisitedMin/MaxWord)를 갱신한다.
 */
static inline void
nfa_mark_visited(WindowAggState *winstate, int16 elemIdx)
{
	int16		w = WORDNUM(elemIdx);

	winstate->nfaVisitedEnds[w] |= ((bitmapword) 1 << BITNUM(elemIdx));
	winstate->nfaVisitedMinWord = Min(winstate->nfaVisitedMinWord, w);
	winstate->nfaVisitedMaxWord = Max(winstate->nfaVisitedMaxWord, w);
}

/*
 * BEGIN을 통해 그룹에 진입하면 이번 반복에서 아직 아무것도 소비하지 않은
 * 상태이고, 뒤이은 DFS는 엡실론 전이만 거치므로, 그 안에서 그룹의 END에
 * 도달하면 그것은 빈 반복이다.  지금 END를 표시해 두어야 한다: 도착 시점에
 * 표시하면 첫 도착에는 너무 늦고, 그러면 사이클 가드가 count >= min인 빈 첫
 * 반복이 다시 루프백하도록 허용해 버린다(TR 19075-5 7.2.8).  루프백은 END에
 * 먼저 도달하므로, BEGIN을 통한 진입일 때만 이 표시가 필요하다.
 */
static inline void
nfa_mark_group_entered(WindowAggState *winstate, RPRPatternElement *begin)
{
	RPRPatternElement *end = &winstate->rpPattern->elements[begin->jump];

	Assert(RPRElemIsBegin(begin));
	Assert(RPRElemIsEnd(end) && end->depth == begin->depth);

	if (RPRElemCanEmptyLoop(end))
		nfa_mark_visited(winstate, begin->jump);
}

/* 전방 선언 */
static RPRNFAState *nfa_state_make(WindowAggState *winstate);
static void nfa_state_free(WindowAggState *winstate, RPRNFAState *state);
static void nfa_state_free_list(WindowAggState *winstate, RPRNFAState *list);
static RPRNFAState *nfa_state_clone(WindowAggState *winstate, int16 elemIdx,
									int32 *counts, bool sourceAbsorbable);
static bool nfa_states_equal(WindowAggState *winstate, RPRNFAState *s1,
							 RPRNFAState *s2);
static void nfa_append_state_unique(WindowAggState *winstate,
									RPRNFAContext *ctx, RPRNFAState *state);
static void nfa_add_matched_state(WindowAggState *winstate, RPRNFAContext *ctx,
								  RPRNFAState *state, int64 matchEndRow);

static RPRNFAContext *nfa_context_make(WindowAggState *winstate);
static void nfa_unlink_context(WindowAggState *winstate, RPRNFAContext *ctx);

static void nfa_update_length_stats(int64 count, NFALengthStats *stats, int64 newLen);
static void nfa_record_context_skipped(WindowAggState *winstate, int64 skippedLen);
static void nfa_record_context_absorbed(WindowAggState *winstate, int64 absorbedLen);

static void nfa_update_absorption_flags(WindowAggState *winstate);
static bool nfa_states_covered(RPRPattern *pattern, RPRNFAContext *older,
							   RPRNFAContext *newer);
static void nfa_try_absorb_context(WindowAggState *winstate, RPRNFAContext *ctx);
static void nfa_absorb_contexts(WindowAggState *winstate);
static void nfa_prune_skipped_contexts(WindowAggState *winstate,
									   RPRNFAContext *ctx);

static bool nfa_eval_var_match(WindowAggState *winstate,
							   RPRPatternElement *elem, RPRVarMatch *varMatched);
static void nfa_match(WindowAggState *winstate, RPRNFAContext *ctx,
					  RPRVarMatch *varMatched, int64 currentPos);
static void nfa_route_to_elem(WindowAggState *winstate, RPRNFAContext *ctx,
							  RPRNFAState *state,
							  RPRPatternElement *targetElem, int64 currentPos);
static void nfa_advance_alt(WindowAggState *winstate, RPRNFAContext *ctx,
							RPRNFAState *state, RPRPatternElement *elem,
							int64 currentPos);
static void nfa_advance_begin(WindowAggState *winstate, RPRNFAContext *ctx,
							  RPRNFAState *state, RPRPatternElement *elem,
							  int64 currentPos);
static void nfa_advance_end(WindowAggState *winstate, RPRNFAContext *ctx,
							RPRNFAState *state, RPRPatternElement *elem,
							int64 currentPos);
static void nfa_advance_var(WindowAggState *winstate, RPRNFAContext *ctx,
							RPRNFAState *state, RPRPatternElement *elem,
							int64 currentPos);
static void nfa_advance_state(WindowAggState *winstate, RPRNFAContext *ctx,
							  RPRNFAState *state, int64 currentPos);
static void nfa_advance(WindowAggState *winstate, RPRNFAContext *ctx,
						int64 currentPos);

static void nfa_invalidate_dependent_vars(WindowAggState *winstate,
										  RPRNFAContext *ctx,
										  int64 currentPos);

/*
 * 이 엔진은 각 행마다 세 단계를 실행한다: match(VAR를 평가하고 죽은 상태를
 * 가지치기), absorb(오래된 컨텍스트가 이미 포함하는 컨텍스트를 버림),
 * advance(상태가 VAR에 멈출 때까지 엡실론 전이를 확장).  요소별 advance 동작,
 * 흡수 논거, 이중 플래그 계약은 README.rpr의 IX장과 X장, 그리고
 * nodes/execnodes.h의 RPRNFAContext 주석에 문서화되어 있다.
 */

/*
 * nfa_state_make
 *
 * NFA 상태를 할당한다.  freeList에 여유가 있으면 그것을 재사용한다.
 * freeList는 매치 시도 사이에 재사용할 수 있도록 WindowAggState에 저장된다.
 */
static RPRNFAState *
nfa_state_make(WindowAggState *winstate)
{
	RPRNFAState *state;

	/* 먼저 free list에서 재사용을 시도한다 */
	if (winstate->nfaStateFree != NULL)
	{
		state = winstate->nfaStateFree;
		winstate->nfaStateFree = state->next;
	}
	else
	{
		/* 올바른 생명주기를 위해 partition 컨텍스트에 할당한다 */
		state = MemoryContextAlloc(winstate->partcontext, winstate->nfaStateSize);
	}

	/* 전체 상태를 0으로 초기화한다 */
	memset(state, 0, winstate->nfaStateSize);

	/* 통계를 갱신한다 */
	winstate->nfaStatesActive++;
	winstate->nfaStatesTotalCreated++;
	winstate->nfaStatesMax = Max(winstate->nfaStatesMax,
								 winstate->nfaStatesActive);

	return state;
}

/*
 * nfa_state_free
 *
 * 나중에 재사용할 수 있도록 상태를 free list에 반환한다.
 */
static void
nfa_state_free(WindowAggState *winstate, RPRNFAState *state)
{
	winstate->nfaStatesActive--;
#ifdef USE_VALGRIND
	/*
	 * 재활용 대신 실제로 해제하여 Valgrind가 use-after-free를 잡아내게 한다
	 */
	pfree(state);
#else
	state->next = winstate->nfaStateFree;
	winstate->nfaStateFree = state;
#endif
}

/*
 * nfa_state_free_list
 *
 * 리스트에 있는 모든 상태를 free list에 반환한다.
 */
static void
nfa_state_free_list(WindowAggState *winstate, RPRNFAState *list)
{
	RPRNFAState *next;

	for (; list != NULL; list = next)
	{
		next = list->next;
		nfa_state_free(winstate, list);
	}
}

/*
 * nfa_state_clone
 *
 * 주어진 elemIdx와 counts로 상태를 복제한다. isAbsorbable은
 * 즉시 계산된다: 상속된 값 AND 새 요소의 플래그이다.  단조 속성:
 * 한 번 false가 되면 모든 전이를 거치는 동안 계속 false로 남는다.
 *
 * 반환된 상태를 연결하는 일은 호출자의 책임이다.
 */
static RPRNFAState *
nfa_state_clone(WindowAggState *winstate, int16 elemIdx,
				int32 *counts, bool sourceAbsorbable)
{
	RPRPattern *pattern = winstate->rpPattern;
	int			maxDepth = pattern->maxDepth;
	RPRNFAState *state = nfa_state_make(winstate);
	RPRPatternElement *elem = &pattern->elements[elemIdx];

	state->elemIdx = elemIdx;
	/*
	 * 도달 가능한 모든 호출자는 살아있는 상태의
	 * counts를 넘기며, maxDepth >= 1이다.
	 */
	Assert(counts != NULL && maxDepth > 0);
	memcpy(state->counts, counts, sizeof(int32) * maxDepth);

	/*
	 * 전이 시점에 isAbsorbable을 즉시 계산한다.  isAbsorbable =
	 * sourceAbsorbable && (elem->flags & ABSORBABLE_BRANCH)이다.
	 * 단조성: 한 번 false가 되면 계속 false로
	 * 남는다(흡수 가능 영역에 다시 들어갈 수 없다).
	 */
	state->isAbsorbable = sourceAbsorbable && RPRElemIsAbsorbableBranch(elem);

	return state;
}

/*
 * nfa_state_exit_to
 *
 * depth를 소유한 구성체 밖으로 상태를 이동시켜 targetIdx로 옮긴 다음, 대상
 * 요소를 반환한다.  호출자는 거기서부터 라우팅한다.
 *
 * 위반해도 겉으로 드러나지 않는 세 가지 규약을 한곳에 모아 둔다:
 *
 * - Count-clear: 다음 점유자가 0으로 진입하도록 빠져나간 depth 슬롯을 0으로
 *   만든다(nfa_advance_begin/nfa_route_to_elem 진입 시 assert로 확인한다).
 * - Arrival increment: END에 도달하면 한 번의 반복이
 *   완료된다(RPR_COUNT_INF에서 포화된다).
 * - isAbsorbable은 대상에 대해 다시 계산되며 단조적이다.  다시 적용해도
 *   멱등이므로 clone 호출자와 in-place 호출자가 이 경로를 공유한다.
 */
static RPRPatternElement *
nfa_state_exit_to(WindowAggState *winstate, RPRNFAState *state, int depth,
				  int16 targetIdx)
{
	RPRPattern *pattern = winstate->rpPattern;
	RPRPatternElement *targetElem;

	state->counts[depth] = 0;
	state->elemIdx = targetIdx;
	targetElem = &pattern->elements[targetIdx];

	state->isAbsorbable = state->isAbsorbable &&
		RPRElemIsAbsorbableBranch(targetElem);

	if (RPRElemIsEnd(targetElem))
		RPRCountIncrement(state->counts[targetElem->depth]);

	return targetElem;
}

/*
 * nfa_states_equal
 *
 * 두 상태가 동등한지(같은 elemIdx와 counts) 검사한다.
 */
static bool
nfa_states_equal(WindowAggState *winstate, RPRNFAState *s1, RPRNFAState *s2)
{
	RPRPattern *pattern = winstate->rpPattern;
	RPRPatternElement *elem;
	int			compareDepth;

	if (s1->elemIdx != s2->elemIdx)
		return false;

	/*
	 * 현재 요소의 depth까지 counts를 비교한다.  elemIdx가
	 * 같은 두 상태는 감싸는 depth 또는 현재 depth의
	 * count가 모두 일치할 때에만(iff) 동등하다.
	 *
	 * +1은 슬롯 산술이다: depth N까지 비교하려면 counts[0..N], 즉 N+1개의
	 * 항목이 필요하다.  더 깊은 슬롯(elem->depth보다 d가 큰 counts[d])은 내부
	 * 그룹의 스크래치 상태를 담고 있으므로 제외한다.  count-clear 정책에 따라
	 * 그런 슬롯은 그것을 소유한 요소가 빠져나갈 때 0으로 지워지므로
	 * (nfa_advance_var와 nfa_match의 인라인 fast path 참고), 동등성 판단에
	 * 참여시켜서는 안 된다.
	 *
	 * XXX 이 비교는 그것이 대변하는 미래보다 더 세밀하다.  max가
	 * RPR_QUANTITY_INF일 때 RPRElemCanLoop()는 모든 count에서 성립하고
	 * RPRElemCanExit()는 min 이상인 모든 count에서 성립하므로, min보다
	 * 위에서만 다른 두 상태는 이 지점부터 동일하게 동작한다.  count는
	 * RPR_COUNT_INF에서 포화되는데 이는 단지 int32 가드일 뿐이므로,
	 * 이 memcmp는 그런 상태들을 계속 구분해 두고 컨텍스트 내 어떤 폐기
	 * 로직도 그것들을 다시 합치지 않는다: 중복 제거는 그것들을 서로
	 * 다르다고 판단하고, nfa_advance()의 FIN 조기 종료는 패턴이 완료될 수
	 * 없는 동안에는 작동하지 않는다.  FIN에 결코 도달하지 못하는 분기하는
	 * 무제한 패턴은 정점에서 Theta(n^2)개의 상태를 유지하며 Theta(n^3)개를
	 * 만들어내고, 이들 각각은 nfa_append_state_unique()의 선형 스캔에서
	 * 다시 검사된다: C가 결코 참이 되지 않는 (A{2,} B)+ C는 80행에서
	 * 30ms, 320행에서 37초가 걸리고 640행에서는 끝나지 않는다.  max가
	 * 무제한일 때 증가량을 min으로 clamp하면 이 memcmp에서 그것들을
	 * 바로 합칠 수 있겠지만, nfa_states_covered()를 포함해 counts[]를
	 * 소비하는 모든 코드가 그 clamp가 의미를 보존함을 증명해야 한다.
	 */
	elem = &pattern->elements[s1->elemIdx];
	compareDepth = elem->depth + 1;

	if (memcmp(s1->counts, s2->counts, sizeof(int32) * compareDepth) != 0)
		return false;

	/* isAbsorbable은 위에서 비교한 요소와 counts로부터 결정된다 */
	Assert(s1->isAbsorbable == s2->isAbsorbable);

	return true;
}

/*
 * nfa_append_state_unique
 *
 * 중복된 상태가 이미 있지 않은 경우에만 상태를 ctx->states 연결
 * 리스트의 끝에 추가한다. 더 이른 상태가 더 나은 어휘적 순서(DFS 순회 순서)를
 * 가지므로 기존 것이 우선하며, 중복이 발견되면 새 상태는 해제된다.
 */
static void
nfa_append_state_unique(WindowAggState *winstate, RPRNFAContext *ctx,
						RPRNFAState *state)
{
	RPRNFAState *s;
	RPRNFAState *tail = NULL;

	/*
	 * 이번 advance가 매치를 기록한 뒤에는 아무것도 대기시키지 않는다:
	 * 여기 남긴 상태는 다음 행까지 살아남아, 거기서 매치를
	 * 완성해 자신보다 우선하는 매치를 대체할 수 있기 때문이다.
	 */
	Assert(!ctx->matchUpdated);

	/* 중복을 검사하고 tail을 찾는다 */
	for (s = ctx->states; s != NULL; s = s->next)
	{
		CHECK_FOR_INTERRUPTS();

		if (nfa_states_equal(winstate, s, state))
		{
			/*
			 * 중복 발견 - 기존 것이 더 나은
			 * 어휘적 순서를 가지므로 새 것을 버린다
			 */
			nfa_state_free(winstate, state);
			winstate->nfaStatesMerged++;
			return;
		}
		tail = s;
	}

	/* 중복이 없으므로 끝에 추가한다 */
	state->next = NULL;
	if (tail == NULL)
		ctx->states = state;
	else
		tail->next = state;
}

/*
 * nfa_add_matched_state
 *
 * FIN에 도달한 상태를 기록하며, 이전 매치가 있으면 그것을 대체한다.
 */
static void
nfa_add_matched_state(WindowAggState *winstate, RPRNFAContext *ctx,
					  RPRNFAState *state, int64 matchEndRow)
{
	/*
	 * 하나의 advance는 매치를 최대 하나만 기록한다.  아래의
	 * 가드들은 matchUpdated가 설정되면 선호도가 낮은 모든 경로를
	 * 멈추므로, 여기에 두 번 도달한다는 것은 FIN에 도달할 수
	 * 있는 어떤 경로가 이 값을 읽지 않았다는 뜻이 된다.
	 */
	Assert(!ctx->matchUpdated);

	if (ctx->matchedState != NULL)
		nfa_state_free(winstate, ctx->matchedState);

	ctx->matchedState = state;
	state->next = NULL;
	ctx->matchEndRow = matchEndRow;

	/*
	 * 되감기 중인 프레임들에게 알린다.  FIN은 방문됨으로 표시되지 않으므로 한
	 * 번의 확장이 그곳에 두 번 이상 도달할 수 있고, 나중에 도착한 쪽이
	 * 선호도가 낮은 쪽이다: 선호도가 낮은 대안을 잘라내는 경로들은 이 값을
	 * 읽고, 다시 기록하는 대신 멈춘다.
	 */
	ctx->matchUpdated = true;
}

/*
 * nfa_context_make
 *
 * NFA 컨텍스트를 할당한다. free list에 여유가 있으면 그것을 재사용한다.
 */
static RPRNFAContext *
nfa_context_make(WindowAggState *winstate)
{
	RPRNFAContext *ctx;

	if (winstate->nfaContextFree != NULL)
	{
		ctx = winstate->nfaContextFree;
		winstate->nfaContextFree = ctx->next;
	}
	else
	{
		/* 올바른 생명주기를 위해 partition 컨텍스트에 할당한다 */
		ctx = MemoryContextAlloc(winstate->partcontext, sizeof(RPRNFAContext));
	}

	ctx->next = NULL;
	ctx->prev = NULL;
	ctx->states = NULL;
	ctx->matchStartRow = -1;
	ctx->matchEndRow = -1;
	ctx->lastProcessedRow = -1;
	ctx->matchedState = NULL;
	ctx->matchUpdated = false;

	/* 패턴에 기반해 2-플래그 흡수 설계를 초기화한다 */
	ctx->hasAbsorbableState = winstate->rpPattern->isAbsorbable;
	ctx->allStatesAbsorbable = winstate->rpPattern->isAbsorbable;

	/* 통계를 갱신한다 */
	winstate->nfaContextsActive++;
	winstate->nfaContextsTotalCreated++;
	winstate->nfaContextsMax = Max(winstate->nfaContextsMax,
								   winstate->nfaContextsActive);

	return ctx;
}

/*
 * nfa_unlink_context
 *
 * 이중 연결된 활성 컨텍스트 리스트에서 컨텍스트를 제거한다.
 * 필요에 따라 head(nfaContext)와 tail(nfaContextTail)을 갱신한다.
 */
static void
nfa_unlink_context(WindowAggState *winstate, RPRNFAContext *ctx)
{
	if (ctx->prev != NULL)
		ctx->prev->next = ctx->next;
	else
		winstate->nfaContext = ctx->next;	/* head였다 */

	if (ctx->next != NULL)
		ctx->next->prev = ctx->prev;
	else
		winstate->nfaContextTail = ctx->prev;	/* tail이었다 */

	ctx->next = NULL;
	ctx->prev = NULL;
}

/*
 * nfa_update_length_stats
 *
 * min/max/total 길이 통계를 갱신하는 헬퍼 함수.  매치/불일치/흡수/건너뜀
 * 길이를 추적할 때 호출된다.
 */
static void
nfa_update_length_stats(int64 count, NFALengthStats *stats, int64 newLen)
{
	if (count == 1)
	{
		stats->min = newLen;
		stats->max = newLen;
	}
	else
	{
		stats->min = Min(stats->min, newLen);
		stats->max = Max(stats->max, newLen);
	}
	stats->total += newLen;
}

/*
 * nfa_record_context_skipped
 *
 * 건너뛴 컨텍스트를 통계에 기록한다.
 */
static void
nfa_record_context_skipped(WindowAggState *winstate, int64 skippedLen)
{
	winstate->nfaContextsSkipped++;
	nfa_update_length_stats(winstate->nfaContextsSkipped,
							&winstate->nfaSkippedLen,
							skippedLen);
}

/*
 * nfa_record_context_absorbed
 *
 * 흡수된 컨텍스트를 통계에 기록한다.
 */
static void
nfa_record_context_absorbed(WindowAggState *winstate, int64 absorbedLen)
{
	winstate->nfaContextsAbsorbed++;
	nfa_update_length_stats(winstate->nfaContextsAbsorbed,
							&winstate->nfaAbsorbedLen,
							absorbedLen);
}

/*
 * nfa_update_absorption_flags
 *
 * 상태가 바뀐 뒤 살아있는 모든 컨텍스트의 흡수 플래그를 갱신한다.
 *
 * 두 플래그가 흡수 동작을 제어한다:
 *   hasAbsorbableState: 컨텍스트에 흡수 가능한 상태가
 *     하나라도 있으면 true이다. 이 플래그는
 *     단조적이다(true -> false로만 바뀐다).  흡수 가능한 상태가
 *     모두 사라지면, 전이를 통해 새 흡수 가능 상태를 만들 수 없다.
 *   allStatesAbsorbable: 컨텍스트의 모든 상태가
 *     흡수 가능하고 기록된 매치가 없으면 true이다.  동적으로
 *     바뀐다(흡수 불가능한 상태가 사라지면서 false -> true로 바뀐다).
 *     단, 기록된 매치가 있으면 false로 고정된다: 흡수하면 어떤
 *     흡수하는 컨텍스트도 재현할 수 없는 매치를 잃게 되기 때문이다.
 *
 * 최적화: hasAbsorbableState가 한 번 false가 되면 그 뒤로 두 플래그 모두
 * 영구히 false로 남으므로 재계산을 건너뛴다.
 */
static void
nfa_update_absorption_flags(WindowAggState *winstate)
{
	if (!winstate->rpPattern->isAbsorbable)
		return;

	for (RPRNFAContext *ctx = winstate->nfaContext; ctx != NULL; ctx = ctx->next)
	{
		bool		hasAbsorbable = false;
		bool		allAbsorbable = true;

		/*
		 * 최적화: hasAbsorbableState가 한 번 false가
		 * 되면 계속 false로 남는다.  다시 계산할 필요가
		 * 없다 - 두 플래그 모두 영구히 false로 남는다.
		 */
		if (!ctx->hasAbsorbableState)
		{
			ctx->allStatesAbsorbable = false;
			continue;
		}

		/* 상태가 없으면 흡수 가능한 상태도 없다 */
		if (ctx->states == NULL)
		{
			ctx->hasAbsorbableState = false;
			ctx->allStatesAbsorbable = false;
			continue;
		}

		/*
		 * 모든 상태를 순회하며 흡수 상태를 검사한다.  상태가 흡수 가능 영역에
		 * 있는지 추적하는 state->isAbsorbable을 사용한다.  이는 비교 지점을
		 * 검사하는 RPRElemIsAbsorbable(elem)과는 다르다.
		 */
		for (RPRNFAState *state = ctx->states; state != NULL; state = state->next)
		{
			CHECK_FOR_INTERRUPTS();

			if (state->isAbsorbable)
				hasAbsorbable = true;
			else
				allAbsorbable = false;
		}

		/*
		 * 기록된 매치가 있으면 이 컨텍스트는 흡수 불가능해진다: 흡수하면 어떤
		 * 흡수하는 컨텍스트도 재현할 수 없는 그 매치를 잃게 되기 때문이다.
		 */
		if (ctx->matchedState != NULL)
			allAbsorbable = false;

		ctx->hasAbsorbableState = hasAbsorbable;
		ctx->allStatesAbsorbable = allAbsorbable;
	}
}

/*
 * nfa_states_covered
 *
 * newer 컨텍스트의 모든 상태가 older 컨텍스트에 의해 "covered"되는지 검사한다.
 *
 * older 컨텍스트가 같은 패턴 요소(elemIdx)에서 해당 depth의 count가
 * newer의 count 이상인 흡수 가능한 상태를 가지고 있으면 newer
 * 상태는 covered된 것이다.  covering 상태는 흡수 가능해야 하는데,
 * 흡수 가능한 상태만이 상위집합 매치를 만들어낼 것을 보장할 수 있기 때문이다.
 *
 * newer의 모든 상태가 covered라면, newer 컨텍스트가 결국 만들어낼
 * 매치는 older 컨텍스트의 매치의 부분집합이 되어 newer는 중복이 된다.
 */
static bool
nfa_states_covered(RPRPattern *pattern, RPRNFAContext *older, RPRNFAContext *newer)
{
	RPRNFAState *newerState;

	for (newerState = newer->states; newerState != NULL; newerState = newerState->next)
	{
		RPRNFAState *olderState;
		RPRPatternElement *elem;
		int			depth;
		bool		found = false;

		/*
		 * 모든 상태가 흡수 가능하다(호출자가 allStatesAbsorbable을 검사한다)
		 */
		elem = &pattern->elements[newerState->elemIdx];
		depth = elem->depth;

		/*
		 * 흡수 비교 지점(RPR_ELEM_ABSORBABLE)에서만 비교한다.  비교 지점은
		 * count-dominance가 newer 컨텍스트의 향후 매치가 older의 부분집합임을
		 * 보장하는 곳이다.
		 */
		if (!RPRElemIsAbsorbable(elem))
			return false;

		for (olderState = older->states; olderState != NULL; olderState = olderState->next)
		{
			CHECK_FOR_INTERRUPTS();

			/* covering 상태도 흡수 가능해야 한다 */
			if (olderState->isAbsorbable &&
				olderState->elemIdx == newerState->elemIdx &&
				olderState->counts[depth] >= newerState->counts[depth])
			{
				found = true;
				break;
			}
		}

		if (!found)
			return false;
	}

	return true;
}

/*
 * nfa_try_absorb_context
 *
 * ctx(newer)를 진행 중인 더 오래된 컨텍스트에 흡수시키려 시도한다.  대상을
 * 찾으면 여기서 ctx의 연결을 끊고 해제한다.
 *
 * 흡수에는 세 가지 조건이 필요하다:
 *   1.  ctx의 모든 상태가 흡수 가능해야 한다(allStatesAbsorbable).  ctx에
 *      흡수 불가능한 상태가 하나라도 있으면 고유한 매치를 만들어낼 수 있다.
 *   2.  older에 흡수 가능한 상태가 하나 이상 있어야 한다(hasAbsorbableState).
 *      흡수 가능한 상태가 없으면 older는 newer의 상태를 covered할 수 없다.
 *   3.  ctx의 모든 상태가 older의 흡수 가능한 상태에 의해 covered되어야 한다.
 *      이는 ctx가 만들어낼 모든 매치를 older가 만들어낼 것을 보장한다.
 *
 * 컨텍스트 리스트는 생성 시각 순으로(prev 체인을 통해 가장 오래된 것부터)
 * 정렬되어 있다.  각 행은 컨텍스트를 최대 하나만 생성하므로, 더 이른
 * 컨텍스트일수록 matchStartRow 값이 더 작다.
 */
static void
nfa_try_absorb_context(WindowAggState *winstate, RPRNFAContext *ctx)
{
	RPRPattern *pattern = winstate->rpPattern;
	RPRNFAContext *older;

	/* 조기 종료: ctx의 모든 상태가 흡수 가능해야 한다 */
	if (!ctx->allStatesAbsorbable)
		return;

	for (older = ctx->prev; older != NULL; older = older->prev)
	{
		CHECK_FOR_INTERRUPTS();

		/*
		 * 불변조건에 의해: ctx->prev 체인은 생성 순서(가장 오래된 것부터)로
		 * 되어 있고, 각 행은 컨텍스트를 최대 하나만
		 * 생성한다.  따라서 이 체인의 모든 컨텍스트는
		 * matchStartRow < ctx->matchStartRow를 만족한다.
		 */

		/* older도 진행 중이어야 한다 */
		if (older->states == NULL)
			continue;

		/* older에 흡수 가능한 상태가 하나 이상 있어야 한다 */
		if (!older->hasAbsorbableState)
			continue;

		/* newer의 모든 상태가 older에 의해 covered되는지 검사한다 */
		if (nfa_states_covered(pattern, older, ctx))
		{
			int64		absorbedLen = ctx->lastProcessedRow - ctx->matchStartRow + 1;

			ExecRPRFreeContext(winstate, ctx);
			nfa_record_context_absorbed(winstate, absorbedLen);
			return;
		}
	}
}

/*
 * nfa_absorb_contexts
 *
 * 메모리 사용량과 계산량을 줄이기 위해 중복 컨텍스트를 흡수한다.
 *
 * A+와 같은 패턴에서는 나중에 시작한 newer 컨텍스트가 더 높은 count를 가진
 * older 컨텍스트의 매치의 부분집합을 만들어낸다.  이런 중복 컨텍스트를 일찍
 * 흡수하면 중복 작업을 피할 수 있다.
 *
 * prev 체인을 통해 tail(가장 최근)에서 head(가장 오래됨) 방향으로 순회한다.
 * 진행 중인 컨텍스트(states != NULL)만 흡수 대상이 된다.  완료된 컨텍스트는
 * 유효한 매치 결과를 나타낸다.
 */
static void
nfa_absorb_contexts(WindowAggState *winstate)
{
	RPRNFAContext *nextCtx;

	if (!winstate->rpPattern->isAbsorbable)
		return;

	for (RPRNFAContext *ctx = winstate->nfaContextTail; ctx != NULL; ctx = nextCtx)
	{
		nextCtx = ctx->prev;

		/*
		 * 진행 중인 컨텍스트만 흡수한다. 완료된 컨텍스트는 유효한 결과이다
		 */
		if (ctx->states != NULL)
			nfa_try_absorb_context(winstate, ctx);
	}
}

/*
 * nfa_prune_skipped_contexts
 *
 * SKIP PAST LAST ROW로 인해 도달할 수 없게 된 컨텍스트를 해제한다.
 *
 * 매치가 matchEndRow까지 이어지는 컨텍스트는 그 지점까지의
 * 모든 행을 소비하므로, 그 범위 안에서 시작한 이후의 컨텍스트는
 * 결코 출력 행을 만들어낼 수 없다.  ctx 이후의 컨텍스트만
 * 해제되며, 이 덕분에 호출자는 리스트를 앞으로 순회할 수 있다.
 */
static void
nfa_prune_skipped_contexts(WindowAggState *winstate, RPRNFAContext *ctx)
{
	int64		matchEndRow = ctx->matchEndRow;

	Assert(winstate->rpSkipTo == ST_PAST_LAST_ROW);

	while (ctx->next != NULL &&
		   ctx->next->matchStartRow <= matchEndRow)
	{
		RPRNFAContext *nextCtx = ctx->next;
		int64		skippedLen;

		Assert(nextCtx->matchStartRow > ctx->matchStartRow);
		Assert(nextCtx->lastProcessedRow >= nextCtx->matchStartRow);

		skippedLen = nextCtx->lastProcessedRow - nextCtx->matchStartRow + 1;
		nfa_record_context_skipped(winstate, skippedLen);

		ExecRPRFreeContext(winstate, nextCtx);
	}
}

/*
 * nfa_eval_var_match
 *
 * VAR 요소가 현재 행과 매치되는지 평가한다.
 *
 * varMatched는 varId로 색인되는 행별 3상태 캐시이다.  평가는 지연(lazy)
 * 방식이다: NFA가 그 변수를 처음 소비할 때(캐시가 RPR_VAR_UNEVALUATED일 때)
 * 여기서 변수의 DEFINE 술어를 평가한 뒤 캐시하므로, 이번 행에서
 * 어떤 활성 상태도 검사하지 않는 변수는 전혀 평가되지 않는다.  이는
 * 불리언 조건을 그 변수에 현재 행을 임시로 매핑한 상태에서만
 * 평가하는 ISO/IEC 19075-5와 일치한다.  varMatched가 NULL이면
 * 모든 VAR가 매치되지 않으며, nfa_match()는 프레임 경계와
 * 파티션 끝 마무리에서 강제로 불일치를 만들기 위해 그렇게 호출된다.
 *
 * 호출자는 소비 전에 현재 행을 미리 준비해 두어야 한다:
 * advance_reduced_frame_nfa()는 currentpos와 nav_match_start를 설정하고,
 * rpr_prepare_row()는 ecxt_outertuple을 설정하며 nav slot 캐시를 무효화하고,
 * nfa_invalidate_dependent_vars()는 matchStartRow가 다른 컨텍스트에 대해
 * nav_match_start를 다시 설치한다(그리고 nav slot 캐시를 무효화한다).
 *
 * ISO/IEC 19075-5 기능 R020에 따라, DEFINE에 나열되지 않은
 * 패턴 변수는 묵시적으로 TRUE이다 -- 모든 행과
 * 매치된다.  이는 varId >= list_length로 검사한다.
 */
static bool
nfa_eval_var_match(WindowAggState *winstate, RPRPatternElement *elem,
				   RPRVarMatch *varMatched)
{
	int			varId;

	/* 이 함수는 VAR 요소에 대해서만 호출되어야 한다 */
	Assert(RPRElemIsVar(elem));

	if (varMatched == NULL)
		return false;

	varId = elem->varId;
	if (varId >= list_length(winstate->defineClauseExprs))
		return true;

	/* 이 변수의 DEFINE 술어를 첫 소비 시점에 지연 평가한다. */
	if (varMatched[varId] == RPR_VAR_UNEVALUATED)
	{
		ExprState  *exprState = list_nth(winstate->defineClauseExprs, varId);

		/*
		 * 이전 술어 평가의 저장 공간을 해제한다.  DEFINE 술어는 아래에
		 * 저장되는 RPRVarMatch 외에는 아무 것도 남기지 않는다 -- 내비게이션
		 * 단계는 이 같은 컨텍스트 안에서 pass-by-ref 결과를 안정화시키며, 그
		 * 결과는 술어가 반환되기 전에 소비된다 -- 따라서 여기서 리셋하는 것은
		 * 항상 안전하며 호출자가 따로 처리할 필요가 없다.
		 */
		ResetExprContext(winstate->rprContext);

		if (ExecQual(exprState, winstate->rprContext))
			varMatched[varId] = RPR_VAR_TRUE;
		else
			varMatched[varId] = RPR_VAR_FALSE;
	}

	return (varMatched[varId] == RPR_VAR_TRUE);
}

/*
 * nfa_match
 *
 * Match 단계(수렴): VAR 요소를 현재 행에 대해 평가한다.  counts만 갱신하고
 * 죽은 상태를 제거한다.  최소한의 전이만 수행한다.
 *
 * VAR 요소의 경우:
 *   - 매치됨: count++ (RPR_COUNT_INF에서 포화), 상태를 유지
 *   - 매치되지 않음: 상태를 제거(count >= min을 만족했을 때 이전 advance에서
 *     이미 exit 대안이 만들어져 있다)
 *
 * max count에 도달한 뒤 END가 이어지는 VAR의 경우:
 *   - 흡수 비교 지점까지 END 요소 체인을 통해 advance한다
 *   - 결정적인 exit만 처리한다.  count는 RPR_COUNT_INF에서 포화되므로 count
 *     >= max만으로는 무제한 VAR를 배제하지 못한다.  그것을 배제하는 것은 흡수
 *     가능 영역 검사이며, 여전히 루프 중인 그룹 안의 무제한 VAR는 이를
 *     통과하지 못한다.
 *   - count >= max인 동안 END 요소를 계속 연쇄한다(반드시 exit해야 하는 경로)
 *
 * Non-VAR 요소(위 체인에 의해 대기하게 된 END만 해당)는 advance 단계를 위해
 * 그대로 유지된다.
 *
 * currentPos는 매칭 로직 자체에서는 쓰이지 않는다.  디버깅을 위해 모든 NFA
 * 헬퍼가 행 인덱스를 지니도록 인자로 받는다.
 */
static void
nfa_match(WindowAggState *winstate, RPRNFAContext *ctx, RPRVarMatch *varMatched,
		  int64 currentPos)
{
	RPRPattern *pattern = winstate->rpPattern;
	RPRPatternElement *elements = pattern->elements;
	RPRNFAState **prevPtr = &ctx->states;
	RPRNFAState *state;
	RPRNFAState *nextState;

	/* VAR 요소를 현재 행에 대해 평가한다. */
	for (state = ctx->states; state != NULL; state = nextState)
	{
		RPRPatternElement *elem = &elements[state->elemIdx];
		int			depth;
		int32		count;

		CHECK_FOR_INTERRUPTS();

		nextState = state->next;

		/*
		 * advance 단계는 VAR 상태만 대기시키며,
		 * 새 컨텍스트는 첫 매치 전에 advance된다.
		 */
		Assert(RPRElemIsVar(elem));

		if (!nfa_eval_var_match(winstate, elem, varMatched))
		{
			/*
			 * 매치되지 않음 - 상태를 제거한다.  count >= min을 만족했을 때
			 * advance 단계에서 exit 대안이 이미 만들어져 있었다.
			 */
			*prevPtr = nextState;
			nfa_state_free(winstate, state);
			continue;
		}

		prevPtr = &state->next;

		depth = elem->depth;
		count = state->counts[depth];

		/*
		 * int32 오버플로를 피하기 위해 RPR_COUNT_INF에서 포화시키며 count를
		 * 증가시킨다.  포화된 count는 이후 "unbounded"로 비교된다.
		 */
		RPRCountIncrement(count);

		/* max 제약을 넘어서는 안 된다 */
		Assert(RPRElemWithinMax(elem, count));

		state->counts[depth] = count;

		/*
		 * max count에 도달했고 다음이 END인 VAR의 경우,
		 * 흡수 비교 지점에 도달할 때까지 END 체인을 통해
		 * advance한다.  결정적인 exit(count >= max, max가 유한)만
		 * 처리하며, 무제한 VAR는 advance 단계를 위해 남겨 둔다.
		 *
		 * ((A (B C){2}){2})+와 같은 중첩 패턴에서는 VAR가 max에 도달하면 exit
		 * 연쇄가 촉발된다: 안쪽 END가 안쪽 그룹의 count를 증가시키고, 이것이
		 * 다시 max에 도달하면 다음 바깥쪽 END로 exit해야 할 수도 있다.  아래
		 * 루프가 이 체인을 따라간다.
		 *
		 * ABSORBABLE_BRANCH는 흡수 가능 영역 안의 요소를 표시하고,
		 * ABSORBABLE은 count-dominance가 평가되는 가장 바깥쪽 비교 지점을
		 * 표시한다.  ABSORBABLE 지점에 도달하거나 아직 루프할 수 있는
		 * 요소(count < max)를 만날 때까지 BRANCH 요소를 연쇄한다.
		 */
		if (RPRElemIsAbsorbableBranch(elem) &&
			!RPRElemIsAbsorbable(elem) &&
			count >= elem->max &&
			RPRElemIsEnd(&elements[elem->next]))
		{
			RPRPatternElement *endElem = &elements[elem->next];
			int			endDepth = endElem->depth;
			int32		endCount = state->counts[endDepth];

			/* 그룹 count를 증가시킨다 */
			RPRCountIncrement(endCount);
			Assert(RPRElemWithinMax(endElem, endCount));

			state->elemIdx = elem->next;
			state->counts[endDepth] = endCount;

			/*
			 * 리프 VAR가 exit했다(max에 도달): nfa_advance_var가 exit 시에
			 * 하는 것과 마찬가지로, 다음 점유자가 0으로 진입하도록 자신의
			 * count를 지운다(이 인라인 경로가 그 exit를 대신한다).  depth >
			 * endDepth이므로, 방금 기록한 그룹 count는 그대로 남는다.
			 */
			Assert(endDepth < depth);
			state->counts[depth] = 0;

			/*
			 * 흡수 가능 영역(ABSORBABLE_BRANCH) 안의
			 * END 요소를 비교 지점(ABSORBABLE)에
			 * 도달할 때까지 연쇄한다.  반드시 exit해야 하는
			 * 경로(count >= max)이고 다음이 END일 때만 계속한다.
			 */
			while (RPRElemIsAbsorbableBranch(endElem) &&
				   !RPRElemIsAbsorbable(endElem) &&
				   endCount >= endElem->max &&
				   RPRElemIsEnd(&elements[endElem->next]))
			{
				RPRPatternElement *outerEnd = &elements[endElem->next];
				int			outerDepth = outerEnd->depth;
				int32		outerCount = state->counts[outerDepth];

				/*
				 * 이 중간 그룹을 exit한다: count-clear 정책에 따라
				 * 자신의 count를 지운다. 이 그룹은 흡수 비교 지점보다
				 * 아래에 있으므로 dominance 비교에서 제외된다.  체인이
				 * 멈추는 비교 지점은 자신의 count를 유지한다.
				 */
				state->counts[endDepth] = 0;

				/* 바깥쪽 그룹 count를 증가시킨다 */
				RPRCountIncrement(outerCount);
				Assert(RPRElemWithinMax(outerEnd, outerCount));

				state->elemIdx = endElem->next;
				state->counts[outerDepth] = outerCount;

				/* 체인의 다음 END로 진행한다 */
				endElem = outerEnd;
				endDepth = outerDepth;
				endCount = outerCount;
			}
		}
	}
}

/*
 * nfa_route_to_elem
 *
 * 상태를 대상 요소로 라우팅한다.  VAR이면 ctx->states에
 * 추가하고, optional이면 skip 경로를 처리한다.
 * 그렇지 않으면 재귀를 통해 엡실론 확장을 계속한다.
 */
static void
nfa_route_to_elem(WindowAggState *winstate, RPRNFAContext *ctx,
				  RPRNFAState *state, RPRPatternElement *targetElem,
				  int64 currentPos)
{
	if (RPRElemIsVar(targetElem))
	{
		RPRNFAState *skipState = NULL;

		/*
		 * count-clear 정책의 진입 측 확인이다: VAR는 항상 깨끗한 슬롯으로
		 * 라우팅된다.  각 요소는 exit할 때 자신의 count를 0으로 지우므로,
		 * 여기서 count가 0이 아니라면 이전 요소에서 새어 나온
		 * 것이다(nfa_advance_var / nfa_advance_end의 exit 처리와 nfa_match의
		 * 인라인 fast path 참고).
		 */
		Assert(state->counts[targetElem->depth] == 0);

		/* state를 해제할 수도 있는 add_unique보다 먼저 skip 상태를 만든다 */
		if (RPRElemCanSkip(targetElem))
		{
			skipState = nfa_state_clone(winstate, targetElem->next,
										state->counts, state->isAbsorbable);

			/*
			 * skip이 바깥쪽 END에 곧바로 도달하면, nfa_advance_var의 exit
			 * 경로가 하는 것과 마찬가지로 그 반복 count를 증가시킨다:
			 * 건너뛴 반복도 실행된 것이며, 그 count는 그룹의 min 검사와
			 * 사이클 가드의 below-min fall-through가 모두 읽는 값이다.
			 */
			nfa_state_exit_to(winstate, skipState, targetElem->depth,
							  targetElem->next);
		}

		if (skipState != NULL && RPRElemIsReluctant(targetElem))
		{
			/*
			 * Reluctant한 optional VAR: 건너뛰기를 선호한다.  skip 경로를
			 * 먼저 탐색하여 enter(매치) 경로보다 우선하게 만든다.  이것이
			 * FIN에 도달하면 최단 매치가 발견된 것이므로 enter 상태는
			 * 버려진다.  이는 leading-position 경로와 optional-group 경로에서
			 * 쓰이는 nfa_advance_begin의 reluctant 분기와 같은 방식이다.
			 */
			nfa_advance_state(winstate, ctx, skipState, currentPos);

			if (ctx->matchUpdated)
			{
				nfa_state_free(winstate, state);
				return;
			}

			nfa_append_state_unique(winstate, ctx, state);
		}
		else
		{
		/* Greedy(또는 skip 불가): enter를 먼저 하고 skip은 나중에 */
			nfa_append_state_unique(winstate, ctx, state);

			if (skipState != NULL)
				nfa_advance_state(winstate, ctx, skipState, currentPos);
		}
	}
	else
	{
		nfa_advance_state(winstate, ctx, state, currentPos);
	}
}

/*
 * nfa_advance_alt
 *
 * ALT 요소를 처리한다: DFS를 통해 모든 분기를 어휘적 순서로 확장한다.
 *
 * ALT.next는 첫 번째 분기의 내용이고 ALT.jump는 그 분기를 끝내는 SEP이다.
 * 각 SEP.jump는 다음 분기의 SEP로 연결되며(마지막은 -1), 각 SEP.next는
 * 다음 분기의 내용이다. 이 순회는 SEP를 읽기만 할 뿐 결코 그 안으로
 * 들어가지 않는다 -- 상태는 항상 분기의 내용에서 만들어진다.
 */
static void
nfa_advance_alt(WindowAggState *winstate, RPRNFAContext *ctx,
				RPRNFAState *state, RPRPatternElement *elem,
				int64 currentPos)
{
	RPRPattern *pattern = winstate->rpPattern;
	RPRPatternElement *elements = pattern->elements;
	RPRElemIdx	branchStart = elem->next;
	RPRElemIdx	sepIdx = elem->jump;

	while (sepIdx != RPR_ELEMIDX_INVALID)
	{
		RPRPatternElement *sepElem;
		RPRNFAState *newState;

		/* 이 분기의 내용에서 독립된 상태를 만든다 */
		newState = nfa_state_clone(winstate, branchStart,
								   state->counts, state->isAbsorbable);

		/* 다음 분기보다 먼저 이 분기를 재귀적으로 처리한다 */
		nfa_advance_state(winstate, ctx, newState, currentPos);

		/*
		 * 분기는 선호 순서대로 나열되므로, 그중 하나가 매치를 기록하고 나면
		 * 이후 분기는 탐색해서는 안 된다: 이후 분기도 같은 DFS 안에서 FIN에
		 * 도달해 선호되는 매치를 대체하거나, 나중 행에서 완료되는 상태를
		 * 대기시켜 그때 대체할 수 있기 때문이다.  nfa_route_to_elem과
		 * nfa_advance_begin의 reluctant 경로와 같은 기법이다.
		 *
		 * A가 거짓이고 B가 참인 행에서 PATTERN (A* | B)를 생각해 보자: A*
		 * 분기가 먼저 탐색되고, 그 skip 경로는 곧장 FIN으로 이어져 여기서 빈
		 * 매치가 기록된다.  break는 그 매치를 그대로 남겨 두는데, 이것이 선호
		 * 순서가 요구하는 바이다.  break가 없다면 B도 확장되어 그 행과 매치될
		 * 것이고, B의 한 행짜리 매치가 마치 패턴이 (B | A*)로 쓰인 것처럼 빈
		 * 매치를 대체해 버릴 것이다.
		 */
		if (ctx->matchUpdated)
			break;

		Assert(sepIdx >= 0 && sepIdx < pattern->numElements);
		sepElem = &elements[sepIdx];
		Assert(RPRElemIsSep(sepElem));

		/* 마지막 분기의 SEP는 링크가 없어 순회가 끝난다 */
		branchStart = sepElem->next;
		sepIdx = sepElem->jump;
	}

	nfa_state_free(winstate, state);
}

/*
 * nfa_advance_begin
 *
 * BEGIN 요소를 처리한다: 그룹 진입 로직.  BEGIN은 최초 그룹 진입
 * 시에만 방문된다.  END로부터의 루프백은 BEGIN을 건너뛰고 첫 자식으로
 * 곧장 간다. 따라서 count-clear 정책에 따라 그룹 자신의 count
 * 슬롯은 진입 시점에 이미 0이다(아래에서 assert로 확인한다).
 * min=0이면 그룹을 지나치는 skip 경로를 만든다.
 */
static void
nfa_advance_begin(WindowAggState *winstate, RPRNFAContext *ctx,
				  RPRNFAState *state, RPRPatternElement *elem,
				  int64 currentPos)
{
	RPRPattern *pattern = winstate->rpPattern;
	RPRPatternElement *elements = pattern->elements;
	RPRNFAState *skipState = NULL;

	/* skip은 END에 도달하지 않고 END의 exit를 통해 빠져나간다 */
	RPRElemIdx	skipIdx = elements[elem->jump].next;

	/*
	 * count-clear 정책의 진입 측 확인이다: 그룹 자신의 count 슬롯은 여기서
	 * 이미 0이다.  BEGIN은 최초 그룹 진입 시에만 방문되며, 이 depth 슬롯의
	 * 이전 점유자가 exit할 때 그것을 지웠다.
	 */
	Assert(state->counts[elem->depth] == 0);

	/* Optional 그룹: skip 경로를 만든다(하지만 아직 라우팅하지 않는다) */
	if (RPRElemCanSkip(elem))
	{
		skipState = nfa_state_clone(winstate, skipIdx,
									state->counts, state->isAbsorbable);

		/*
		 * nfa_route_to_elem에서와 마찬가지로, 바깥쪽 END에 곧바로 도달하는
		 * skip도 그 END가 속한 그룹의 한 반복으로 계산된다.
		 */
		nfa_state_exit_to(winstate, skipState, elem->depth, skipIdx);
	}

	if (skipState != NULL && RPRElemIsReluctant(elem))
	{
		/* Reluctant: skip을 먼저(더 적은 반복을 선호), enter는 나중에 */
		nfa_route_to_elem(winstate, ctx, skipState,
						  &elements[skipIdx], currentPos);

		/* skip이 매치되었다: 그 위에 그룹으로 enter하지 않는다 */
		if (ctx->matchUpdated)
		{
			nfa_state_free(winstate, state);
			return;
		}

		nfa_mark_group_entered(winstate, elem);
		state->elemIdx = elem->next;
		nfa_route_to_elem(winstate, ctx, state,
						  &elements[state->elemIdx], currentPos);
	}
	else
	{
		/*
		 * Greedy이거나 non-optional: 첫 자식으로 라우팅한다.  optional
		 * 그룹(skipState != NULL, greedy min=0)에서는 skip 경로도 추가로
		 * 만든다.  non-optional 그룹(skipState == NULL, min>0)에서는 아래
		 * 가드가 skip-path 동작을 억제한다.
		 */
		nfa_mark_group_entered(winstate, elem);
		state->elemIdx = elem->next;
		nfa_route_to_elem(winstate, ctx, state,
						  &elements[state->elemIdx], currentPos);

		/* Enter가 매치되었다: 그 위에 skip을 취하지 않는다 */
		if (ctx->matchUpdated)
		{
			if (skipState != NULL)
				nfa_state_free(winstate, skipState);
			return;
		}

		if (skipState != NULL)
		{
			nfa_route_to_elem(winstate, ctx, skipState,
							  &elements[skipIdx], currentPos);
		}
	}
}

/*
 * nfa_advance_end
 *
 * END 요소를 처리한다: 그룹 반복 로직.  count와 min/max를 비교해 루프백할지
 * exit할지 결정한다.
 */
static void
nfa_advance_end(WindowAggState *winstate, RPRNFAContext *ctx,
				RPRNFAState *state, RPRPatternElement *elem,
				int64 currentPos)
{
	RPRPattern *pattern = winstate->rpPattern;
	RPRPatternElement *elements = pattern->elements;
	int			depth = elem->depth;
	int32		count = state->counts[depth];

	if (!RPRElemCanExit(elem, count))
	{
		RPRPatternElement *jumpElem;
		RPRNFAState *ffState = NULL;
		RPRPatternElement *nextElem = NULL;

		/*----------
		 * 그룹 본체가 nullable(RPR_ELEM_EMPTY_LOOP)이면 두 경로를 탐색한다:
		 *
		 * 1.  Loop-back 경로: 다음 반복에서 실제 매치를
		 *    시도한다(state, 아래에서 수정됨).
		 *
		 * 2.  Fast-forward 경로: 그룹 뒤로 곧장 건너뛰어,
		 * 남은 필수 반복을 모두 빈 매치로 취급한다(ffState).
		 * 경쟁하는 greedy/reluctant 루프 상태를 만들지 않도록
		 * (nfa_advance_end가 아니라) elem->next로 라우팅한다.
		 *
		 * 순서를 결정하는 것은 그룹 자신의 탐욕이 아니라 본체이다: 본체가 빈
		 * 매치를 선호할 때(RPR_ELEM_EMPTY_PREFERRED) 정확히 그때만
		 * fast-forward가 먼저 온다.  그것이 FIN에 도달하면, 더 긴 매치가
		 * 선호되는 매치를 대체할 수 없도록 loop-back은 버려진다 -- 아래의
		 * min<=count<max 분기와 같은 방식이다.  ffState의 스냅샷은 state를
		 * 수정하기 전에 찍는데, 이 지점부터 두 경로가 갈라지기 때문이다.
		 *----------
		 */
		if (RPRElemCanEmptyLoop(elem))
		{
			ffState = nfa_state_clone(winstate, state->elemIdx,
									  state->counts, state->isAbsorbable);

			/*
			 * 여기서는 nfa_state_exit_to()의 isAbsorbable
			 * 재계산이 아무 효과가 없다: EMPTY_LOOP 그룹은
			 * 결코 흡수 가능 영역에 있지 않기 때문이다.
			 */
			nextElem = nfa_state_exit_to(winstate, ffState, depth,
										 elem->next);
		}

		/*
		 * loop-back 상태를 준비한다.  방문 표시는 의도적으로 그대로
		 * 남겨 둔다.  nfa_advance_state의 사이클 가드를 참고하라.
		 */
		state->elemIdx = elem->jump;
		jumpElem = &elements[state->elemIdx];

		if (ffState != NULL && RPRElemIsEmptyPreferred(elem))
		{
			/* 본체가 빈 매치를 선호: fast-forward(exit)를 먼저 취한다 */
			nfa_route_to_elem(winstate, ctx, ffState, nextElem,
							  currentPos);

			/* fast-forward가 매치되었다: 그 위에 loop-back하지 않는다 */
			if (ctx->matchUpdated)
			{
				nfa_state_free(winstate, state);
				return;
			}

			/* loop-back은 나중에 */
			nfa_route_to_elem(winstate, ctx, state, jumpElem,
							  currentPos);
		}
		else
		{
			/*
			 * Greedy(또는 non-nullable): loop-back을
			 * 먼저, fast-forward는 나중에
			 */
			nfa_route_to_elem(winstate, ctx, state, jumpElem,
							  currentPos);

			/* loop-back이 매치되었다: 그 위에 fast-forward하지 않는다 */
			if (ctx->matchUpdated)
			{
				if (ffState != NULL)
					nfa_state_free(winstate, ffState);
				return;
			}

			if (ffState != NULL)
				nfa_route_to_elem(winstate, ctx, ffState, nextElem,
								  currentPos);
		}
	}
	else if (!RPRElemCanLoop(elem, count))
	{
		/* 반드시 exit해야 한다: 최대 반복 횟수에 도달했다. */
		RPRPatternElement *nextElem;

		nextElem = nfa_state_exit_to(winstate, state, depth, elem->next);

		nfa_route_to_elem(winstate, ctx, state, nextElem, currentPos);
	}
	else
	{
		/*
		 * min과 max 사이(반복이 최소 한 번 이상)에서는 exit할 수도
		 * loop할 수도 있다.  Greedy: loop를 먼저(더 많은 반복을 선호).
		 * Reluctant: exit를 먼저(더 적은 반복을 선호).
		 */
		RPRNFAState *exitState;
		RPRPatternElement *jumpElem;
		RPRPatternElement *nextElem;

		/*
		 * exit 상태를 먼저
		 * 만든다(state를 수정하기 전의 원래 counts가 필요하다)
		 */
		exitState = nfa_state_clone(winstate, elem->next,
									state->counts, state->isAbsorbable);
		nextElem = nfa_state_exit_to(winstate, exitState, depth, elem->next);

		/* loop 상태를 준비한다 */
		state->elemIdx = elem->jump;
		jumpElem = &elements[state->elemIdx];

		if (RPRElemIsReluctant(elem))
		{
			/* exit을 먼저(reluctant에 선호됨) */
			nfa_route_to_elem(winstate, ctx, exitState, nextElem,
							  currentPos);

			/* exit이 매치되었다: 그 위에 loop하지 않는다 */
			if (ctx->matchUpdated)
			{
				nfa_state_free(winstate, state);
				return;
			}

			/* loop은 나중에 */
			nfa_route_to_elem(winstate, ctx, state, jumpElem,
							  currentPos);
		}
		else
		{
			/* loop을 먼저(greedy에 선호됨) */
			nfa_route_to_elem(winstate, ctx, state, jumpElem,
							  currentPos);

			/* loop이 매치되었다: 그 위에 exit하지 않는다 */
			if (ctx->matchUpdated)
			{
				nfa_state_free(winstate, exitState);
				return;
			}

			/* exit은 나중에 */
			nfa_route_to_elem(winstate, ctx, exitState, nextElem,
							  currentPos);
		}
	}
}

/*
 * nfa_advance_var
 *
 * VAR 요소를 처리한다: loop/exit 전이.  match 단계 이후, 모든 VAR 상태는
 * 매치된 상태이다 - 다음 동작을 결정한다.
 */
static void
nfa_advance_var(WindowAggState *winstate, RPRNFAContext *ctx,
				RPRNFAState *state, RPRPatternElement *elem,
				int64 currentPos)
{
	int			depth = elem->depth;
	int32		count = state->counts[depth];

	Assert(RPRElemCanLoop(elem, count) || RPRElemCanExit(elem, count));

	/* 도달 가능한 모든 VAR에 대해 elem->next는 유효한 인덱스여야 한다 */
	Assert(elem->next >= 0 &&
		   elem->next < winstate->rpPattern->numElements);

	if (RPRElemCanLoop(elem, count) && RPRElemCanExit(elem, count))
	{
		/*
		 * loop과 exit 둘 다 가능하다.  Greedy:
		 * loop을 먼저(더 긴 매치를 선호).  Reluctant:
		 * exit을 먼저(더 짧은 매치를 선호).
		 */
		RPRNFAState *cloneState;
		RPRPatternElement *nextElem;

		/*
		 * 우선순위가 가장 높은 경로를 위해 상태를 clone한다.  greedy에서는
		 * clone이 loop 상태이고, reluctant에서는 clone이 exit 상태이다.
		 */
		if (RPRElemIsReluctant(elem))
		{
			/* exit용으로 clone하고, 원본은 loop에 남긴다 */
			cloneState = nfa_state_clone(winstate, elem->next,
										 state->counts, state->isAbsorbable);
			nextElem = nfa_state_exit_to(winstate, cloneState, depth,
										 elem->next);

			/* exit을 먼저(reluctant에 선호됨) */
			nfa_route_to_elem(winstate, ctx, cloneState, nextElem,
							  currentPos);

			/* exit이 매치되었다: 그 위에 loop하지 않는다 */
			if (ctx->matchUpdated)
			{
				nfa_state_free(winstate, state);
				return;
			}

			/* loop은 나중에 */
			nfa_append_state_unique(winstate, ctx, state);
		}
		else
		{
			/* loop용으로 clone하고, 원본은 exit에 사용한다 */
			cloneState = nfa_state_clone(winstate, state->elemIdx,
										 state->counts, state->isAbsorbable);

			/* loop을 먼저(greedy에 선호됨) */
			nfa_append_state_unique(winstate, ctx, cloneState);

			/* exit은 나중에: nfa_match는 결정적인 exit만 처리한다 */
			nextElem = nfa_state_exit_to(winstate, state, depth, elem->next);

			nfa_route_to_elem(winstate, ctx, state, nextElem,
							  currentPos);
		}
	}
	else if (!RPRElemCanExit(elem, count))
	{
		/*
		 * 최솟값 미만이므로 exit는 불법이며, 다음 행에서 이 VAR를 다시
		 * 매치하는 것만이 유일하게 합법적인 계속이다.  advance 단계는 상태가
		 * 다음에 어디로 갈지만 결정하며, counts[depth]는 이미 지금까지 이
		 * VAR가 매치한 횟수를 담고 있다: 이번 행에서 매치된 상태는 match
		 * 단계에서 그 값이 증가되었고, 아직 아무것도 매치하지 못한 상태 -- 새
		 * 컨텍스트의 초기 상태이거나 skip으로 여기에 라우팅된 상태 -- 는 0인
		 * 채로 도착한다.  어느 쪽이든 같은 VAR에 계속 머무는 것은 상태를
		 * 바꾸지 않고 새 세대에 추가함으로써 표현된다.  대신 버린다면 최솟값
		 * 미만인 모든 수량자가 좌초된다: A{2} B는 첫 A 매치 뒤에 상태를 잃고
		 * 결코 완료되지 못할 것이다.
		 *
		 * clone은 필요 없다.  계속되는 경로가 하나뿐이므로 원본의 소유권은
		 * 그대로 리스트로 넘어간다.
		 */
		nfa_append_state_unique(winstate, ctx, state);
	}
	else
	{
		/* exit만 가능: 다음 요소로 advance한다 */
		RPRPatternElement *nextElem;

		nextElem = nfa_state_exit_to(winstate, state, depth, elem->next);

		nfa_route_to_elem(winstate, ctx, state, nextElem, currentPos);
	}
}

/*
 * nfa_advance_state
 *
 * 하나의 상태를 엡실론 전이를 통해 재귀적으로 처리한다.  DFS 순회는 상태가
 * ctx->states에 어휘적 순서로 추가되도록 보장한다.
 */
static void
nfa_advance_state(WindowAggState *winstate, RPRNFAContext *ctx,
				  RPRNFAState *state, int64 currentPos)
{
	RPRPattern *pattern = winstate->rpPattern;
	RPRPatternElement *elem;

	Assert(state->elemIdx >= 0 && state->elemIdx < pattern->numElements);

	/*
	 * 매우 복잡한 패턴에서 스택 오버플로를 막고, 확장이 중단 없이 얼마나 오래
	 * 실행되는지를 제한한다: 이 DFS의 모든 사이클은 여기를 다시 거쳐 가므로,
	 * 진입할 때마다 한 번씩 검사하면 그 간격이 재귀 깊이로 제한된다.
	 */
	check_stack_depth();
	CHECK_FOR_INTERRUPTS();

	/*
	 * 사이클 감지이다.  nullable END만 표시되므로, 비트가
	 * 설정되어 있다는 것은 본체가 이번 반복에서 방금
	 * 빈 매치를 도출했다는 뜻이다: DFS는 엡실론 전이만
	 * 거치므로 마지막 방문 이후 어떤 행도 소비되지 않았다.
	 *
	 * 그 밖에는 방어가 필요 없다: 재방문은 진행이 전혀 없을 때만 사이클이며,
	 * 그 외의 모든 loop-back은 행을 소비했다.  이를 버리면 매치를 완전히
	 * 잃는다 -- ((A | B B){1,3}){3}은 그러면 아무것도 찾지 못한다.
	 */
	if (winstate->nfaVisitedEnds[WORDNUM(state->elemIdx)] &
		((bitmapword) 1 << BITNUM(state->elemIdx)))
	{
		RPRPatternElement *hitElem = &pattern->elements[state->elemIdx];

		Assert(RPRElemIsEnd(hitElem) && RPRElemCanEmptyLoop(hitElem));

		if (RPRElemCanExit(hitElem, state->counts[hitElem->depth]))
		{
			RPRPatternElement *nextElem;

			/* 마무리가 끝난 뒤에는 END가 항상 유효한 exit 대상을 가진다. */
			Assert(hitElem->next != RPR_ELEMIDX_INVALID);

			/*
			 * 상태를 버리는 대신 여기서 그룹을 떠나고, 그 exit를 이 순위에서
			 * 나열한다: 버리면 "그룹을 떠난다"가 나머지 대안들보다
			 * 낮은 순위로 밀려나고, 그러면 선호도가 낮은 분기가 매치가
			 * 소비해서는 안 될 행을 소비하게 된다.  하한 이상에서는 빈
			 * 반복이 수량자를 멈춘다(SQL/RPR은 여기서 Perl을 따른다).
			 */

			nextElem = nfa_state_exit_to(winstate, state, hitElem->depth,
										 hitElem->next);

			nfa_route_to_elem(winstate, ctx, state, nextElem, currentPos);
			return;
		}

		/*
		 * 하한 미만에서는 수량자가 exit할 수 없으므로 일반적인 must-loop
		 * 경로로 그대로 진행한다.  각 빈 반복의 도착 증가가 count를
		 * 전진시키므로 결국 min에 도달해 위에서 exit한다.  대신 여기서 표시를
		 * 지운다면 중첩된 reluctant 루프에 대한 가드도 함께 무력화되어, 그 빈
		 * 반복이 무한히 재귀하게 된다: 한 개의 매치되는 행에 대한
		 * (A (B*?)+?){2,}가 그 예이다.
		 */
	}

	elem = &pattern->elements[state->elemIdx];

	/*
	 * 테스트되는 것은 오직 nullable END뿐이다. 위의 가드를 참고하라.
	 *
	 * XXX 이것은 사이클을 제한할 뿐 비용을 제한하지는 않는다.  ALT와 BEGIN을
	 * 표시하지 않고 남겨 두면 한 번의 확장 안에서 몇 번이든 다시 들어갈 수
	 * 있으므로, 분기가 모두 nullable인 일련의 alternation은 상태가 아니라
	 * 경로를 나열하게 된다: nfa_advance_alt()는 분기마다 한 번씩 재귀하고
	 * fillRPRPatternAlt()는 모든 분기의 꼬리를 같은 요소로 수렴시키므로, 그런
	 * alternation k개는 비용이 2^k가 된다.  (A?|B?){30}은 30분 넘게 걸리지만
	 * 재귀 깊이는 k에 머물러 check_stack_depth()가 결코 작동하지 않는다.
	 * 비용을 제한하려면 (elemIdx, counts)로 이루어진 재방문 키가 필요한데, 이
	 * 비트맵은 elemIdx만을 식별한다.
	 */
	if (RPRElemCanEmptyLoop(elem))
		nfa_mark_visited(winstate, state->elemIdx);

	switch (elem->varId)
	{
		case RPR_VARID_FIN:
			nfa_add_matched_state(winstate, ctx, state, currentPos);
			break;

		case RPR_VARID_ALT:
			nfa_advance_alt(winstate, ctx, state, elem, currentPos);
			break;

		case RPR_VARID_BEGIN:
			nfa_advance_begin(winstate, ctx, state, elem, currentPos);
			break;

		case RPR_VARID_END:
			nfa_advance_end(winstate, ctx, state, elem, currentPos);
			break;

		default:
			/* VAR 요소이다; SEP은 여기에 도달해서는 안 된다 */
			Assert(!RPRElemIsSep(elem) && RPRElemIsVar(elem));
			nfa_advance_var(winstate, ctx, state, elem, currentPos);
			break;
	}
}

/*
 * nfa_advance
 *
 * Advance 단계(발산): 살아남은 모든 상태로부터 전이한다.  매치된 VAR 상태를
 * 가지고 match 단계 뒤에 호출되거나, 컨텍스트 생성 시 초기 엡실론 확장을 위해
 * 호출된다(currentPos = startPos - 1).  재귀적 DFS를 사용해 어휘적 순서를
 * 유지하며 상태를 순서대로 처리한다.
 */
static void
nfa_advance(WindowAggState *winstate, RPRNFAContext *ctx, int64 currentPos)
{
	RPRNFAState *states = ctx->states;
	RPRNFAState *state;

	ctx->states = NULL;			/* 다시 만들 것이다 */
	ctx->matchUpdated = false;

	/* 각 상태를 어휘적 순서(이전 advance의 DFS 순서)로 처리한다 */
	while (states != NULL)
	{
		CHECK_FOR_INTERRUPTS();

		/*
		 * 각 상태의 DFS 확장 전에 방문 비트맵을 지운다.  지워야 하는 것은
		 * 이전 리셋 이후 건드린 범위뿐이다(nfa_mark_visited에서
		 * 갱신하는 high-water 마크로 추적한다).  작은 NFA에서는
		 * 이것이 배열 전체이지만, advance마다 몇 개의 요소에만 DFS가
		 * 도달하는 큰 NFA에서는 비트맵 전체를 순회하지 않아도 된다.
		 */
		if (winstate->nfaVisitedMaxWord >= winstate->nfaVisitedMinWord)
		{
			memset(&winstate->nfaVisitedEnds[winstate->nfaVisitedMinWord], 0,
				   sizeof(bitmapword) *
				   (winstate->nfaVisitedMaxWord -
					winstate->nfaVisitedMinWord + 1));
			winstate->nfaVisitedMinWord = PG_INT16_MAX;
			winstate->nfaVisitedMaxWord = -1;
		}

		state = states;
		states = states->next;

		/*
		 * 경계 규약이다: nfa_advance_state의 엡실론 확장 DFS로
		 * 넘어가기 전에 여기서 state->next를 NULL로 리셋한다.  내부
		 * 분기들(nfa_advance_var, nfa_advance_begin/end/alt)은
		 * state->next가 이미 NULL이라고 간주하고 스스로 리셋하지 않는다.
		 * 또 다른 연결 지점은 nfa_append_state_unique이며,
		 * 이곳은 ctx->states에 추가할 때 그것을 설정한다.
		 */
		state->next = NULL;

		nfa_advance_state(winstate, ctx, state, currentPos);

		/*
		 * 조기 종료이다: 이번 advance에서 FIN에 새로 도달했다면, 남은 이전
		 * 상태들은 어휘적 순서가 더 나쁘므로 가지치기할 수 있다.  새로 도착한
		 * FIN만 검사한다(이전 행에서의 도착은 아니다).
		 */
		if (ctx->matchUpdated && states != NULL)
		{
			nfa_state_free_list(winstate, states);
			break;
		}
	}
}

/*
 * nfa_invalidate_dependent_vars
 *		공유 평가의 nav_match_start와 matchStartRow가 다른 컨텍스트에 대해,
 *		match_start에 의존하는 DEFINE 변수를 무효화한다.
 *
 * defineMatchStartDependent에 속한 변수만 영향을 받는다: nfa_match()가 이
 * 컨텍스트의 matchStartRow에 맞춰 지연 재평가하도록 RPR_VAR_UNEVALUATED로
 * 리셋된다.  나머지 변수는 nav_match_start를 읽지 않으므로 컨텍스트 사이에서
 * 캐시된 값을 그대로 유지한다.
 *
 * nav_match_start는 이 컨텍스트를 위해 설치된 뒤 그대로 남는다:
 * FIRST/LAST는 평가 시점, 즉 나중에 nfa_match() 안에서 그것을 읽으므로
 * 여기서 복원해서는 안 된다.  다음 컨텍스트의 무효화나, 다음 행에서
 * advance_reduced_frame_nfa가 하는 공유 설정이 그것을 덮어쓴다.
 */
static void
nfa_invalidate_dependent_vars(WindowAggState *winstate, RPRNFAContext *ctx,
							  int64 currentPos)
{
	int			varIdx = -1;

	if (bms_is_empty(winstate->defineMatchStartDependent) ||
		ctx->matchStartRow == winstate->nav_match_start)
		return;

	/*
	 * 호출자는 지연 평가를 위해 winstate->currentpos를 스캔 위치에 유지한다.
	 */
	Assert(winstate->currentpos == currentPos);

	/*
	 * FIRST/LAST를 위해 이 컨텍스트의 match_start를 설치하고 그대로 유지한다.
	 */
	winstate->nav_match_start = ctx->matchStartRow;

	/* match_start가 바뀌었으므로 nav_slot 캐시를 무효화한다 */
	winstate->nav_slot_pos = -1;

	/* 의존하는 변수만 리셋하여 지연 재평가되게 한다. */
	while ((varIdx = bms_next_member(winstate->defineMatchStartDependent,
									 varIdx)) >= 0)
		winstate->nfaVarMatched[varIdx] = RPR_VAR_UNEVALUATED;
}


/***********************************************************************
 * nodeWindowAgg.c에 노출되는 API
 ***********************************************************************/

/*
 * ExecRPRStartContext
 *
 * 주어진 위치에서 새 매치 컨텍스트를 시작한다. 컨텍스트와 상태
 * 흡수 플래그를 초기화하고, 엡실론 전이(ALT 분기, optional 요소)를
 * 확장하기 위해 초기 advance를 수행한다. 컨텍스트를
 * winstate->nfaContext 리스트의 tail에 추가한다.
 */
RPRNFAContext *
ExecRPRStartContext(WindowAggState *winstate, int64 startPos)
{
	RPRNFAContext *ctx;
	RPRPattern *pattern = winstate->rpPattern;

	ctx = nfa_context_make(winstate);
	ctx->matchStartRow = startPos;
	ctx->states = nfa_state_make(winstate); /* 요소 0의 초기 상태 */

	/*
	 * 지금까지 유일한 상태는 요소 0에 있으며, computeAbsorbability()는
	 * 패턴을 흡수 가능하다고 판단할 때 정확히 그 경우에만
	 * 그 요소를 ABSORBABLE_BRANCH로 표시한다.  따라서 패턴의
	 * 플래그가 이 상태에 대한 답이 된다 -- nfa_context_make()가
	 * 설정한 컨텍스트 플래그에 대해서도 이미 그랬던 것처럼.
	 */
	Assert(RPRElemIsAbsorbableBranch(&pattern->elements[0]) ==
		   pattern->isAbsorbable);
	ctx->states->isAbsorbable = pattern->isAbsorbable;

	/*
	 * 활성 컨텍스트 리스트(이중 연결, 가장 오래된 것부터)의 tail에 추가한다.
	 * matchStartRow는 리스트를 따라 증가하므로 head가 가장 작은 값을 가진다
	 * -- 다른 코드가 의존하는 순서이다.  한 행에서 시작하는 컨텍스트는 최대
	 * 하나이다: update_reduced_frame의 on-demand 경로는 컨텍스트가 없는
	 * 곳에서만 하나를 만든다.
	 */
	Assert(winstate->nfaContextTail == NULL ||
		   startPos > winstate->nfaContextTail->matchStartRow);
	ctx->prev = winstate->nfaContextTail;
	ctx->next = NULL;
	if (winstate->nfaContextTail != NULL)
		winstate->nfaContextTail->next = ctx;
	else
		winstate->nfaContext = ctx; /* 첫 컨텍스트가 head가 된다 */
	winstate->nfaContextTail = ctx;

	/*
	 * 초기 advance(발산)이다: ALT 분기를 확장하고 min=0인 VAR 요소의 exit
	 * 상태를 만든다.  이는 컨텍스트를 첫 행의 match 단계를 위해 준비시킨다.
	 *
	 * 아직 소비된 행이 없으므로 currentPos로 startPos - 1을 사용한다.  엡실론
	 * 전이를 통해 FIN에 도달하면 matchEndRow = startPos - 1이 되는데, 이것이
	 * 빈 매치를 나타내는 방식이다.
	 */
	nfa_advance(winstate, ctx, startPos - 1);

	return ctx;
}

/*
 * ExecRPRFreeContext
 *
 * 컨텍스트를 활성 리스트에서 연결 해제하고 free list로 반환한다.  컨텍스트
 * 안의 상태도 모두 해제한다.
 */
void
ExecRPRFreeContext(WindowAggState *winstate, RPRNFAContext *ctx)
{
	/* 먼저 활성 리스트에서 연결을 해제한다 */
	nfa_unlink_context(winstate, ctx);

	/* 통계를 갱신한다 */
	winstate->nfaContextsActive--;

	if (ctx->states != NULL)
		nfa_state_free_list(winstate, ctx->states);
	if (ctx->matchedState != NULL)
		nfa_state_free(winstate, ctx->matchedState);

	ctx->next = winstate->nfaContextFree;
	ctx->states = NULL;
	ctx->matchStartRow = -1;
	ctx->matchEndRow = -1;
	ctx->lastProcessedRow = -1;
	ctx->matchedState = NULL;
	ctx->matchUpdated = false;
	ctx->hasAbsorbableState = false;
	ctx->allStatesAbsorbable = false;
	winstate->nfaContextFree = ctx;
}

/*
 * ExecRPRRecordContextSuccess
 *
 * 성공한 컨텍스트를 통계에 기록한다.
 */
void
ExecRPRRecordContextSuccess(WindowAggState *winstate, int64 matchLen)
{
	winstate->nfaMatchesSucceeded++;
	nfa_update_length_stats(winstate->nfaMatchesSucceeded,
							&winstate->nfaMatchLen,
							matchLen);
}

/*
 * ExecRPRRecordContextFailure
 *
 * 실패한 컨텍스트를 통계에 기록한다. failedLen ==
 * 1이면 pruned로 집계한다(첫 행에서 실패).  failedLen
 * > 1이면 mismatched로 집계하고 길이 통계를 갱신한다.
 */
void
ExecRPRRecordContextFailure(WindowAggState *winstate, int64 failedLen)
{
	if (failedLen == 1)
	{
		winstate->nfaContextsPruned++;
	}
	else
	{
		winstate->nfaMatchesFailed++;
		nfa_update_length_stats(winstate->nfaMatchesFailed,
								&winstate->nfaFailLen,
								failedLen);
	}
}

/*
 * ExecRPRProcessRow
 *
 * 한 행에 대해 모든 컨텍스트를 처리한다:
 *   1. 모든 컨텍스트를 match한다(수렴) - VAR를 평가하고 죽은 상태를 가지치기
 *   2. 중복 컨텍스트를 흡수한다 - 수렴 이후가 이상적인 시점
 *   3. 모든 컨텍스트를 advance한다(발산) - 다음 행을 위한 새 상태를 만든다
 */
void
ExecRPRProcessRow(WindowAggState *winstate, int64 currentPos)
{
	RPRVarMatch *varMatched = winstate->nfaVarMatched;
	int64		frameOffset = -1;	/* -1은 파티션 끝까지의 프레임을 뜻한다 */

	/*
	 * 제한된 프레임(ROWS ... N FOLLOWING)인지 확인한다.  각 컨텍스트는
	 * matchStartRow + offset에 기반한 자신만의 프레임 끝을 필요로 한다.
	 */
	if (!(winstate->frameOptions & FRAMEOPTION_END_UNBOUNDED_FOLLOWING))
		frameOffset = DatumGetInt64(winstate->endOffsetValue);

	/*
	 * 단순하거나 상태가 적은 패턴을 위해 행마다 한 번씩 쿼리 취소를 허용한다
	 */
	CHECK_FOR_INTERRUPTS();

	/*
	 * 1단계: 모든 컨텍스트를 match한다(수렴).  VAR 요소를 평가하고 counts를
	 * 갱신하며 죽은 상태를 제거한다.
	 */
	for (RPRNFAContext *ctx = winstate->nfaContext; ctx != NULL; ctx = ctx->next)
	{
		if (ctx->states == NULL)
			continue;

		/* 프레임 경계를 검사한다 - 도달하면 컨텍스트를 마무리한다 */
		if (frameOffset >= 0)
		{
			int64		ctxFrameEnd;

			/*
			 * 오버플로 시 PG_INT64_MAX로 clamp한다.  frameOffset은
			 * PG_INT64_MAX만큼 클 수 있으므로(예: "ROWS <huge> FOLLOWING"),
			 * "frameOffset + 1" 부분식에서 부호 있는 정수 오버플로를 피하기
			 * 위해 offset을 더하는 것과 뒤이은 +1을 각각 따로 검사하는 두
			 * 단계로 나눈다.
			 */
			if (pg_add_s64_overflow(ctx->matchStartRow, frameOffset,
									&ctxFrameEnd) ||
				pg_add_s64_overflow(ctxFrameEnd, 1, &ctxFrameEnd))
				ctxFrameEnd = PG_INT64_MAX;

			/*
			 * currentPos는 호출마다 정확히 1씩 증가하고, 마무리된 컨텍스트는
			 * 위의 states == NULL 가드에서 건너뛰어지므로, ctxFrameEnd에는
			 * 도달할 수 있을 뿐 그것을 넘어설 수는 없다. 이 Assert는 그
			 * 불변조건을 깨는 향후 변경을, 경계를 조용히 지나쳐 버리는 대신
			 * 즉시 실패로 드러나게 만든다.
			 */
			Assert(currentPos <= ctxFrameEnd);

			if (currentPos == ctxFrameEnd)
			{
				/* 프레임 경계에 도달: 강제로 불일치 처리한다 */
				nfa_match(winstate, ctx, NULL, currentPos);
				continue;
			}
		}

		/*
		 * 이 컨텍스트의 matchStartRow가 공유 평가에서 쓰인 것과 다르다면,
		 * nfa_match()가 이 컨텍스트의 matchStartRow로 지연 재평가하도록
		 * match_start에 의존하는 변수를 무효화한다.
		 *
		 * head 컨텍스트는 명시적인 무효화를 거치지 않는다:
		 * advance_reduced_frame_nfa가 설치해 둔 주변 nav_match_start에
		 * 의존하므로, 다른 어떤 컨텍스트가 nav_match_start를 덮어쓰기 전에
		 * 도달해야 한다.
		 */
		Assert(ctx != winstate->nfaContext ||
			   ctx->matchStartRow == winstate->nav_match_start);

		nfa_invalidate_dependent_vars(winstate, ctx, currentPos);

		nfa_match(winstate, ctx, varMatched, currentPos);
		ctx->lastProcessedRow = currentPos;
	}

	/*
	 * 2단계: 중복 컨텍스트를 흡수한다.  match 단계 이후 상태들이 수렴했으므로
	 * 흡수에 이상적인 시점이다.  먼저 상태 제거로 인해 바뀌었을 수 있는 흡수
	 * 플래그를 갱신한다.
	 */
	nfa_update_absorption_flags(winstate);
	nfa_absorb_contexts(winstate);

	/*
	 * 3단계: 모든 컨텍스트를 advance한다(발산).  살아남아
	 * 매치된 상태로부터 새 상태(loop/exit)를 만든다.
	 */
	for (RPRNFAContext *ctx = winstate->nfaContext; ctx != NULL; ctx = ctx->next)
	{
		if (ctx->states == NULL)
			continue;

		nfa_advance(winstate, ctx, currentPos);

		if (ctx->matchUpdated && winstate->rpSkipTo == ST_PAST_LAST_ROW)
			nfa_prune_skipped_contexts(winstate, ctx);
	}
}

/*
 * ExecRPRCleanupDeadContexts
 *
 * 실패한 컨텍스트(활성 상태도 없고 매치도 없는)를 제거한다.  이들은
 * 정상 처리 중에 실패한 컨텍스트이며, pruned(길이가 1인 경우)
 * 또는 mismatched(길이가 1보다 큰 경우)로 집계되어야 한다.
 */
void
ExecRPRCleanupDeadContexts(WindowAggState *winstate, RPRNFAContext *excludeCtx)
{
	RPRNFAContext *ctx;
	RPRNFAContext *next;

	for (ctx = winstate->nfaContext; ctx != NULL; ctx = next)
	{
		CHECK_FOR_INTERRUPTS();

		next = ctx->next;

		/* 대상 컨텍스트와 아직 처리 중인 컨텍스트는 건너뛴다 */
		if (ctx == excludeCtx || ctx->states != NULL)
			continue;

		/*
		 * 매치를 기록한 컨텍스트는 건너뛴다(SKIP 로직이 처리한다).
		 * matchEndRow가 아니라 matchedState를 검사한다: 빈 매치는
		 * matchStartRow - 1에서 끝나므로, 행 길이로 검사하면 이를 실패로
		 * 오인해 pruned나 mismatched로 집계하게 된다.
		 */
		if (ctx->matchedState != NULL)
			continue;

		/*
		 * 실패한 컨텍스트이다: 아래에서 항상 제거된다.  실제로 자신의 시작
		 * 행을 처리한 경우에만 실패 통계를 기록한다.  파티션을 넘어선 행을
		 * 위해 생성된 컨텍스트는 집계되지 않고 제거된다.
		 */
		if (ctx->lastProcessedRow >= ctx->matchStartRow)
		{
			ExecRPRRecordContextFailure(winstate,
										ctx->lastProcessedRow - ctx->matchStartRow + 1);
		}

		ExecRPRFreeContext(winstate, ctx);
	}
}

/*
 * ExecRPRFinalizeAllContexts
 *
 * 파티션 끝 분류 정책이다: 행이 다 떨어졌을 때 여전히 추적 중인 VAR 상태를
 * 모두 죽여서, cleanup이 모든 컨텍스트에 걸쳐 균일하게 ctx->states == NULL을
 * 보게 한다. 이 함수가 실행될 즈음에는 진짜 FIN 도달은 모두 이미 진행 중에
 * 기록되어 있다.  여기에는 세 가지 형태가 남는다:
 *   - 순수 추적(matchedState == NULL): 결코 오지 않을 입력을 기다리는 VAR
 *     상태(예: 파티션 끝에서 패턴 중간에 있는 A+ B).
 *   - 빈 매치 후보 + 추적(matchedState != NULL, matchEndRow < matchStartRow):
 *     초기 advance의 skip을 통한 FIN 도달이 빈 매치를 기록했지만 VAR 상태는
 *     여전히 더 긴 매치를 쫓고 있다(예: greedy A*).
 *   - 실제 매치 + 추적(matchedState != NULL, matchEndRow >= matchStartRow):
 *     매치가 기록되었지만 VAR 상태는 여전히 더 긴 매치를 위해 루프 중이다.
 *
 * VAR를 죽이면 cleanup에서 순수 추적이 실패로 재분류된다(그렇지 않으면 통계에
 * 기여하지 못한 채 남아 있게 된다).  나머지 둘은 모두 기록된 매치를 지니므로
 * cleanup이 건너뛴다: 빈 매치는 실패가 아니라 길이 0의 성공이며,
 * update_reduced_frame이 head-context 경로를 통해 그렇게 등록한다.  이들도
 * 파티션 끝 분류가 한곳에 집중되도록 여전히 같은 균일한 경로를 거친다.
 *
 * 구현: NULL을 넘긴 nfa_match는 VAR 불일치를 강제하고, 뒤이은 nfa_advance는
 * 남은 엡실론 전이를 모두 비운다.
 */
void
ExecRPRFinalizeAllContexts(WindowAggState *winstate, int64 lastPos)
{
	RPRNFAContext *ctx;

	for (ctx = winstate->nfaContext; ctx != NULL; ctx = ctx->next)
	{
		CHECK_FOR_INTERRUPTS();

		if (ctx->states != NULL)
		{
			nfa_match(winstate, ctx, NULL, lastPos);

		/*
		 * 방어적 조치: advance는 VAR 상태만 남기는데, 위에서 모두 제거했다.
		 */
			nfa_advance(winstate, ctx, lastPos);
		}
	}
}
