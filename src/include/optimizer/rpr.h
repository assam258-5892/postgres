/*-------------------------------------------------------------------------
 *
 * rpr.h
 *	  플래너를 위한 행 패턴 인식 패턴 컴파일
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/optimizer/rpr.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef RPR_H
#define RPR_H

#include "nodes/parsenodes.h"
#include "nodes/plannodes.h"
#include "nodes/primnodes.h"

/* 한계와 특수 값 */
/*
 * 최대 패턴 변수 ID이다.  패턴 변수는 varId 0 부터 RPR_VARID_MAX 까지를
 * 차지하며(서로 다른 변수 240 개), 상위 니블이 설정된(0xF0부터 0xFF까지)
 * varId 는 모두 제어 요소용으로 예약한다.  현재 사용 중인
 * 값만이 아니라 상위 니블 전체를 예약해 두면 향후 제어 요소를 위한
 * 여지가 남고, 이 범위는 릴리스 전에만 안전하게 좁힐 수 있다.
 */
#define RPR_VARID_MAX		0xEF	/* 패턴 변수는 0 부터 0xEF까지이다 */

/*
 * RPR_COUNT_INF 는 int32 오버플로를 피하기 위해 런타임 반복 횟수가 포화되는
 * 값이다(아래 RPRCountIncrement() 참고).  포화된 카운트가 무제한 수량자의
 * max와 마찬가지로 "unbounded"로 비교되도록, 이 값은 (위에서 include한
 * nodes/parsenodes.h에 있는) RPR_QUANTITY_INF 로 정의한다.
 */
#define RPR_COUNT_INF		RPR_QUANTITY_INF
#define RPR_ELEMIDX_MAX		PG_INT16_MAX	/* 최대 패턴 요소 개수 */
#define RPR_ELEMIDX_INVALID	((RPRElemIdx) -1)	/* 유효하지 않은 인덱스 */
#define RPR_DEPTH_MAX		PG_UINT8_MAX	/* RPRDepth에 255 개 레벨이
											 * 들어가며, depth는 0 부터
											 * 시작하므로 허용되는 최대 중첩
											 * 깊이는 254 이다 */

/* 예약된 제어 요소 varIds (상위 니블 0xF; 0xF0-0xFA는 남겨둠) */
#define RPR_VARID_BEGIN		((RPRVarId) 0xFB)	/* 그룹 시작 */
#define RPR_VARID_END		((RPRVarId) 0xFC)	/* 그룹 끝 */
#define RPR_VARID_ALT		((RPRVarId) 0xFD)	/* 교대 시작 */
#define RPR_VARID_SEP		((RPRVarId) 0xFE)	/* 교대 분기 구분자 */
#define RPR_VARID_FIN		((RPRVarId) 0xFF)	/* 패턴 종료 */

/* 요소 플래그 */
#define RPR_ELEM_RELUCTANT			0x01	/* 소극적(비탐욕적) 수량자 */
#define RPR_ELEM_EMPTY_LOOP			0x02	/* END: 그룹 본문이 빈 매치를
											 * 만들어 낼 수 있다 */
#define RPR_ELEM_EMPTY_PREFERRED	0x04	/* END: 그룹 본문이 빈 매치를
											 * 선호한다 */
/*
 * 아래 두 흡수(absorption) 플래그는 README.rpr V-7
 * ("Absorbability Analysis")에서 설명하며, 실제 예시는 Appendix B에 있다. 이
 * 플래그를 설정하는 분석은 optimizer/plan/rpr.c의 computeAbsorbability()이다.
 */
#define RPR_ELEM_ABSORBABLE_BRANCH	0x08	/* 흡수 가능 영역 안의 요소 */
#define RPR_ELEM_ABSORBABLE			0x10	/* 흡수 판단 지점 */

/* RPRPatternElement 용 접근자 매크로 */
#define RPRElemIsReluctant(e)			(((e)->flags & RPR_ELEM_RELUCTANT) != 0)
#define RPRElemCanEmptyLoop(e)			(((e)->flags & RPR_ELEM_EMPTY_LOOP) != 0)
#define RPRElemIsEmptyPreferred(e)		(((e)->flags & RPR_ELEM_EMPTY_PREFERRED) != 0)
#define RPRElemIsAbsorbableBranch(e)	(((e)->flags & RPR_ELEM_ABSORBABLE_BRANCH) != 0)
#define RPRElemIsAbsorbable(e)			(((e)->flags & RPR_ELEM_ABSORBABLE) != 0)
#define RPRElemIsVar(e)			((e)->varId <= RPR_VARID_MAX)
#define RPRElemIsBegin(e)		((e)->varId == RPR_VARID_BEGIN)
#define RPRElemIsEnd(e)			((e)->varId == RPR_VARID_END)
#define RPRElemIsAlt(e)			((e)->varId == RPR_VARID_ALT)
#define RPRElemIsSep(e)			((e)->varId == RPR_VARID_SEP)
#define RPRElemIsFin(e)			((e)->varId == RPR_VARID_FIN)
#define RPRElemCanSkip(e)		((e)->min == 0)
#define RPRElemIsUnbounded(e)	((e)->max == RPR_QUANTITY_INF)
/* 수량자 검사: 포화된 카운트는 무제한으로 비교된다 */
#define RPRElemCanLoop(e, count)	\
	(RPRElemIsUnbounded(e) || (count) < (e)->max)
#define RPRElemCanExit(e, count)	((count) >= (e)->min)
/* 카운트가 더 늘어날 수 있는지가 아니라 한계 안에 머물러 있는지를 검사한다 */
#define RPRElemWithinMax(e, count)	\
	(RPRElemIsUnbounded(e) || (count) <= (e)->max)

/* 반복을 하나 더 세되, int32가 오버플로되지 않도록 포화시킨다 */
#define RPRCountIncrement(count)	\
	do { if ((count) < RPR_COUNT_INF) (count)++; } while (0)

extern RPRPattern *buildRPRPattern(RPRPatternNode *pattern, List *defineClause,
								   RPSkipTo rpSkipTo, int frameOptions,
								   bool hasMatchStartDependent);

#endif							/* RPR_H */
