/*-------------------------------------------------------------------------
 *
 * rpr.c
 *	  플래너를 위한 행 패턴 인식 패턴 컴파일
 *
 * 이 파일은 RPR 패턴 파스 트리를 최적화하고 WindowAgg 가 NFA로 실행할 수
 * 있도록 평탄화된 요소 배열로 컴파일하는 함수를 담고 있다.
 *
 * 주요 구성 요소:
 *   1.  패턴 최적화: 컴파일 전에 패턴을 단순화한다 (예: 중첩된 SEQ/ALT를
 *      평탄화하고, 연속된 변수를 병합)
 *   2. 패턴 컴파일: 파스 트리를 NFA용 평탄화된 요소 배열로 변환한다
 *   3. 흡수 분석: O(n^2)->O(n) 최적화를 위한 플래그를 계산한다
 *
 * 컨텍스트 흡수 최적화:
 *   패턴이 탐욕적 무제한 요소로 시작하면(예: A+ 또는 (A B)+), 더 최근
 *   컨텍스트는 더 오래된 컨텍스트보다 긴 매치를 만들어 낼 수 없다.  불필요한
 *   최근 컨텍스트를 흡수(제거)하면 A+ B와 같은 패턴에서 복잡도를 O(n^2)에서
 *   O(n)으로 줄일 수 있다.
 *
 *   흡수 분석은 두 가지 요소 플래그를 사용한다:
 *   - RPR_ELEM_ABSORBABLE: 어디를 비교할지 표시한다(판단 지점)
 *   - RPR_ELEM_ABSORBABLE_BRANCH: 흡수 가능 영역을 표시한다
 *
 *   EXPLAIN은 Pattern: 줄에 둘 다 표시하며,
 *   #는 판단 지점을, ~는 영역을 나타낸다.
 *
 *   전체 설계 설명은 computeAbsorbability()와 isUnboundedStart() 앞의 상세한
 *   주석을 참고하라.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/optimizer/plan/rpr.c
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"

#include "common/int.h"
#include "miscadmin.h"
#include "optimizer/rpr.h"

/* 전방 선언 */
static int64 rprNodeRowCount(RPRPatternNode *node);
static int64 rprBodyRowCount(List *children);
static bool rprBodyHasUniformLength(List *children);
static bool rprChildrenMatchAt(List *children, int start, List *content);
static List *rprGroupContent(RPRPatternNode *group);
static bool rprTryAddIteration(RPRPatternNode *group);
pg_nodiscard static List *flattenSeqChildren(List *children);
pg_nodiscard static List *mergeConsecutiveVars(List *children);
pg_nodiscard static List *mergeConsecutiveGroups(List *children);
pg_nodiscard static List *mergeConsecutiveAlts(List *children);
pg_nodiscard static List *mergeGroupPrefixSuffix(List *children);
static RPRPatternNode *optimizeSeqPattern(RPRPatternNode *pattern);

pg_nodiscard static List *flattenAltChildren(List *children);
pg_nodiscard static List *removeDuplicateAlternatives(List *children);
static RPRPatternNode *optimizeAltPattern(RPRPatternNode *pattern);

static RPRPatternNode *tryMultiplyQuantifiers(RPRPatternNode *pattern);
static RPRPatternNode *tryUnwrapGroup(RPRPatternNode *pattern);
static RPRPatternNode *optimizeGroupPattern(RPRPatternNode *pattern);

static RPRPatternNode *optimizeRPRPattern(RPRPatternNode *pattern);
static void scanRPRPatternRecursive(RPRPatternNode *node, char **varNames,
									int *numVars, int *numElements,
									RPRDepth depth, RPRDepth *maxDepth);
static void scanRPRPattern(RPRPatternNode *node, char **varNames, int *numVars,
						   int *numElements, RPRDepth *maxDepth);
static RPRPattern *makeRPRPattern(int numVars, int numElements,
								  RPRDepth maxDepth, char **varNamesStack);
static RPRVarId getVarIdFromPattern(RPRPattern *pat, const char *varName);
static RPRElemFlags fillRPRPatternVar(RPRPatternNode *node, RPRPattern *pat,
									  int *idx, RPRDepth depth);
static RPRElemFlags fillRPRPatternGroup(RPRPatternNode *node, RPRPattern *pat,
										int *idx, RPRDepth depth);
static RPRElemFlags fillRPRPatternAlt(RPRPatternNode *node, RPRPattern *pat,
									  int *idx, RPRDepth depth);
static RPRElemFlags fillRPRPattern(RPRPatternNode *node, RPRPattern *pat,
								   int *idx, RPRDepth depth);
static void finalizeRPRPattern(RPRPattern *result);

static bool isFixedLengthChildren(RPRPattern *pattern,
								  RPRPatternElement *elem);
static bool isUnboundedStart(RPRPattern *pattern, RPRPatternElement *elem);
static void computeAbsorbabilityRecursive(RPRPattern *pattern,
										  RPRPatternElement *elem,
										  bool *hasAbsorbable);
static void computeAbsorbability(RPRPattern *pattern);

/*
 * rprNodeRowCount
 *		노드가 항상 소비하는 행 수, 달라질 수 있으면 -1 이다.
 *
 * 길이가 같은 Alternative들은 고정으로 취급한다: 서로 다른 변수를 고를 수는
 * 있지만, 행 수는 결코 달라지지 않는다.
 */
static int64
rprNodeRowCount(RPRPatternNode *node)
{
	int64		len;

	check_stack_depth();

	switch (node->nodeType)
	{
		case RPR_PATTERN_VAR:
			if (node->min != node->max)
				return -1;
			return node->min;

		case RPR_PATTERN_ALT:
			len = -1;
			foreach_node(RPRPatternNode, branch, node->children)
			{
				int64		branchLen = rprNodeRowCount(branch);

				if (branchLen < 0 || (len >= 0 && branchLen != len))
					return -1;
				len = branchLen;
			}
			return len;

		case RPR_PATTERN_SEQ:
		case RPR_PATTERN_GROUP:
			len = rprBodyRowCount(node->children);
			if (len < 0)
				return -1;
			if (node->nodeType == RPR_PATTERN_SEQ)
				return len;
			if (node->min != node->max)
				return -1;
			len *= node->min;
			/* 이렇게 큰 카운트는 실제 행에서는 나올 수 없다 */
			if (len >= RPR_QUANTITY_INF)
				return -1;
			return len;
	}

	pg_unreachable();
	return -1;
}

/*
 * rprBodyRowCount
 *		children이 순서대로 항상 소비하는 행 수, 달라질 수 있으면 -1 이다.
 */
static int64
rprBodyRowCount(List *children)
{
	int64		total = 0;

	foreach_node(RPRPatternNode, child, children)
	{
		int64		len = rprNodeRowCount(child);

		if (len < 0)
			return -1;
		total += len;

		/* 이렇게 큰 카운트는 실제 행에서는 나올 수 없다 */
		if (total >= RPR_QUANTITY_INF)
			return -1;
	}
	return total;
}

/*
 * rprBodyHasUniformLength
 *		children이 항상 같은 수의 행을 소비하는가?
 */
static bool
rprBodyHasUniformLength(List *children)
{
	return rprBodyRowCount(children) >= 0;
}

/*
 * rprChildrenMatchAt
 *		[start, start + list_length(content)) 위치의 children 셀들이 content와
 *		요소 단위로 일치하는가?
 *
 * 그 범위가 children 안에 들어가지 않으면 false를 반환하므로, 리스트의 양쪽
 * 끝을 향해 훑어 가는 호출자는 그냥 물어보기만 하면 된다.
 */
static bool
rprChildrenMatchAt(List *children, int start, List *content)
{
	int			offset = 0;

	if (start < 0 || start + list_length(content) > list_length(children))
		return false;

	foreach_node(RPRPatternNode, want, content)
	{
		RPRPatternNode *have;

		have = list_nth_node(RPRPatternNode, children, start + offset);
		if (!equal(have, want))
			return false;
		offset++;
	}

	return true;
}

/*
 * rprGroupContent
 *		GROUP이 나타내는 요소들을, 시퀀스에 나타나는 순서 그대로.
 *
 * GROUP은 자식을 하나만 가지며, 다중 요소 본문은
 * SEQ로 감싸여 들어오므로, 이를 풀어서 둘러싼 시퀀스의
 * 요소들과 비교한다: (A B)+는 시퀀스 A B를 가진다.
 */
static List *
rprGroupContent(RPRPatternNode *group)
{
	List	   *content = group->children;

	if (list_length(content) == 1)
	{
		RPRPatternNode *inner = linitial_node(RPRPatternNode, content);

		if (inner->nodeType == RPR_PATTERN_SEQ)
			content = inner->children;
	}

	Assert(list_length(content) > 0);
	return content;
}

/*
 * rprTryAddIteration
 *		표현 가능하다면 GROUP의 수량자를 반복 1 회만큼 늘린다.
 *
 * 무제한 max는 카운트가 아니라 "no limit"을 나타내므로 그대로 두며,
 * 오버플로가 일어날 수 없다.  유한한 한계는 RPR_QUANTITY_INF 보다 작아야
 * 한다: 그 마커에 도달하면 무제한으로 읽히기 때문이다.  두 한계 중
 * 어느 하나라도 여유가 없으면 노드를 건드리지 않고 false를 반환한다.
 */
static bool
rprTryAddIteration(RPRPatternNode *group)
{
	if (group->min >= RPR_QUANTITY_INF - 1)
		return false;
	if (group->max != RPR_QUANTITY_INF &&
		group->max >= RPR_QUANTITY_INF - 1)
		return false;

	group->min += 1;
	if (group->max != RPR_QUANTITY_INF)
		group->max += 1;
	return true;
}

/*
 * flattenSeqChildren
 *		children을 재귀적으로 최적화하고 중첩된 SEQ를 평탄화한다.
 *
 * 예:
 *   SEQ(A, SEQ(B, C)) -> SEQ(A, B, C)
 *
 * 최적화된 children으로 이루어진 새 리스트를 반환하며, 중첩된
 * SEQ의 children은 부모 리스트에 평탄화되어 들어간다. 이 파일의
 * 헬퍼들은 두 가지 관례를 따른다 -- 이 함수와 flattenAltChildren()은
 * 시작했을 때보다 길어질 수 있으므로 새 리스트를 만들고, 나머지는 이미
 * 가진 셀들을 압축한다 -- 그래서 호출자는 반환값을 항상 대입해야 한다.
 */
static List *
flattenSeqChildren(List *children)
{
	List	   *newChildren = NIL;

	foreach_node(RPRPatternNode, child, children)
	{
		RPRPatternNode *opt = optimizeRPRPattern(child);

		/*
		 * GROUP{1,1}은 optimizeGroupPattern 에서 이미 풀렸어야 한다;
		 * tryUnwrapGroup()은 reluctance와 무관하게 이를 수행한다.
		 */
		Assert(!(opt->nodeType == RPR_PATTERN_GROUP &&
				 opt->min == 1 && opt->max == 1));

		if (opt->nodeType == RPR_PATTERN_SEQ)
		{
			newChildren = list_concat(newChildren,
									  list_copy(opt->children));
		}
		else
		{
			newChildren = lappend(newChildren, opt);
		}
	}

	return newChildren;
}

/*
 * mergeConsecutiveVars
 *		연속으로 동일한 VAR 노드를 병합한다.
 *
 * 예:
 *   A{m1,M1} A{m2,M2} -> A{m1+m2, M1+M2}  (INF + x = INF)
 *
 * 같은 변수 이름을 가진, reluctant가 아닌 VAR 노드만 병합한다.
 */
static List *
mergeConsecutiveVars(List *children)
{
	int			writepos = 0;
	int			readpos = 0;

	while (readpos < list_length(children))
	{
		RPRPatternNode *node = list_nth_node(RPRPatternNode, children, readpos);
		int			runlen = 1;

		if (node->nodeType == RPR_PATTERN_VAR && !node->reluctant)
		{
			/* 뒤따르는 VAR들을 맞는 한 node로 접어 넣는다 */
			while (readpos + runlen < list_length(children))
			{
				RPRPatternNode *other;
				int			newmin;
				int			newmax;

				other = list_nth_node(RPRPatternNode, children, readpos + runlen);

				if (other->nodeType != RPR_PATTERN_VAR)
					break;

				/*
				 * 같은 변수에 대해 탐욕적 수량자 뒤에 소극적 수량자가
				 * 오는 경우는 하나의 수량자로 표현할 수 없다: 표준의
				 * leftmost-choice-first 규칙(ISO/IEC TR 19075-5 7.2)이
				 * 관찰 가능하게 만드는 대로, 이 쌍은 두 번째 수량자가
				 * 결정되기 전에 첫 번째 수량자의 카운트를 먼저 정한다.
				 * 이들을 병합하면 선호되는 매치가 바뀌므로, 여기서 멈춘다.
				 */
				if (other->reluctant)
					break;

				if (strcmp(node->varName, other->varName) != 0)
					break;

				/*
				 * RPR_QUANTITY_INF 는 카운트가 아니라 무제한을 의미한다: 그
				 * 값에 도달하는 유한한 합은 표현 가능하므로, 따로 거부한다.
				 */
				if (node->max == RPR_QUANTITY_INF ||
					other->max == RPR_QUANTITY_INF)
					newmax = RPR_QUANTITY_INF;
				else if (pg_add_s32_overflow(node->max, other->max, &newmax) ||
						 newmax >= RPR_QUANTITY_INF)
					break;		/* 대체 경로: 이 쌍은 병합하지 않고 둔다 */

				if (pg_add_s32_overflow(node->min, other->min, &newmin) ||
					newmin >= RPR_QUANTITY_INF)
					break;		/* 대체 경로: 이 쌍은 병합하지 않고 둔다 */

				node->min = newmin;
				node->max = newmax;
				runlen++;
			}
		}

		/*
		 * 살아남은 것들은 앞으로 압축된다.  writepos는 readpos를
		 * 결코 앞지르지 않으므로, 아직 읽어야 할 셀을 덮어쓸 수 없다.
		 */
		lfirst(list_nth_cell(children, writepos++)) = node;
		readpos += runlen;
	}

	return list_truncate(children, writepos);
}

/*
 * mergeConsecutiveGroups
 *		연속으로 동일한 GROUP 노드를 병합한다.
 *
 * 예:
 *   (A B)+ (A B)+ -> (A B){2,}
 *
 * 동일한 children을 가진, reluctant가 아닌 GROUP 노드만 병합한다.
 *
 * 본문은 고정된 수의 행을 소비해야 한다.  그렇지 않으면 병합이
 * 선호되는 매치를 바꾼다: 두 그룹은 반복 횟수를 서로 나눠 가지며, 이는
 * 병합된 형태에는 없는 선택 지점이다.  본문이 고정이면 소비하는 행 수가
 * 반복 횟수에 맞춰 늘어나므로, 두 형태 모두 같은 순서로 같은 행에
 * 도달한다; 고정이 아니면 그렇지 않을 수 있다 -- (A | B B)+ (A | B B)+는
 * (A | B B){2,}가 두 번 반복하는 자리에서 네 행짜리 매치를 선호한다.
 */
static List *
mergeConsecutiveGroups(List *children)
{
	int			writepos = 0;
	int			readpos = 0;

	while (readpos < list_length(children))
	{
		RPRPatternNode *node = list_nth_node(RPRPatternNode, children, readpos);
		int			runlen = 1;

		if (node->nodeType == RPR_PATTERN_GROUP && !node->reluctant)
		{
			/* 뒤따르는 GROUP들을 맞는 한 node로 접어 넣는다 */
			while (readpos + runlen < list_length(children))
			{
				RPRPatternNode *other;
				int			newmin;
				int			newmax;

				other = list_nth_node(RPRPatternNode, children, readpos + runlen);

				if (other->nodeType != RPR_PATTERN_GROUP || other->reluctant)
					break;

				if (!equal(node->children, other->children))
					break;

				/* 본문은 고정된 수의 행을 소비해야 한다; 위 설명 참고 */
				if (!rprBodyHasUniformLength(node->children))
					break;

				/*
				 * RPR_QUANTITY_INF 는 카운트가 아니라 무제한을 의미한다: 그
				 * 값에 도달하는 유한한 합은 표현 가능하므로, 따로 거부한다.
				 */
				if (node->max == RPR_QUANTITY_INF ||
					other->max == RPR_QUANTITY_INF)
					newmax = RPR_QUANTITY_INF;
				else if (pg_add_s32_overflow(node->max, other->max, &newmax) ||
						 newmax >= RPR_QUANTITY_INF)
					break;		/* 대체 경로: 이 쌍은 병합하지 않고 둔다 */

				if (pg_add_s32_overflow(node->min, other->min, &newmin) ||
					newmin >= RPR_QUANTITY_INF)
					break;		/* 대체 경로: 이 쌍은 병합하지 않고 둔다 */

				node->min = newmin;
				node->max = newmax;
				runlen++;
			}
		}

		/*
		 * 살아남은 것들은 앞으로 압축된다.  writepos는 readpos를
		 * 결코 앞지르지 않으므로, 아직 읽어야 할 셀을 덮어쓸 수 없다.
		 */
		lfirst(list_nth_cell(children, writepos++)) = node;
		readpos += runlen;
	}

	return list_truncate(children, writepos);
}

/*
 * mergeConsecutiveAlts
 *		연속으로 동일한 ALT 노드를 GROUP으로 병합한다.
 *
 * 예:
 *   (A | B) (A | B) (A | B) -> (A | B){3}
 *
 * GROUP{1,1}을 풀고 나면 (A | B) 같은 단독 alternation은
 * SEQ 안에서 ALT 노드가 된다. 이 단계는 연속으로 동일한 ALT
 * 노드를 찾아내어, 이를 적절한 수량자를 가진 GROUP으로 감싼다.
 */
static List *
mergeConsecutiveAlts(List *children)
{
	int			writepos = 0;
	int			readpos = 0;

	while (readpos < list_length(children))
	{
		RPRPatternNode *node = list_nth_node(RPRPatternNode, children, readpos);
		int			count = 1;

		/*
		 * 수량자는 결코 ALT에 붙지 않으므로,
		 * 이 중 어느 것도 reluctant가 아니다
		 */
		if (node->nodeType == RPR_PATTERN_ALT)
		{
			/* 이것과 동일한 ALT의 연속 구간 길이를 센다 */
			while (readpos + count < list_length(children))
			{
				RPRPatternNode *other;

				other = list_nth_node(RPRPatternNode, children, readpos + count);

				if (!equal(node, other))
					break;

				count++;
			}

			if (count > 1)
			{
				/* 이 구간을 GROUP{count,count}(ALT)로 감싼다 */
				RPRPatternNode *group = makeNode(RPRPatternNode);

				group->nodeType = RPR_PATTERN_GROUP;
				group->min = count;
				group->max = count;
				group->reluctant = false;
				group->location = -1;
				group->children = list_make1(node);
				node = group;
			}
		}

		/*
		 * 살아남은 것들은 앞으로 압축된다.  writepos는 readpos를
		 * 결코 앞지르지 않으므로, 아직 읽어야 할 셀을 덮어쓸 수 없다.
		 */
		lfirst(list_nth_cell(children, writepos++)) = node;
		readpos += count;
	}

	return list_truncate(children, writepos);
}

/*
 * mergeGroupPrefixSuffix
 *		시퀀스의 prefix/suffix를 일치하는 children을 가진 GROUP으로 병합한다.
 *
 * GROUP의 children이 SEQ 안에서 그 GROUP 앞의 prefix로, 또는 뒤의 suffix로
 * (또는 둘 다로) 나타나면, GROUP의 수량자를 늘려서 이들을 병합한다. 이 과정은
 * 반복적으로 실행된다: A B A B (A B)+ A B -> (A B){4,}.
 *
 * 알고리즘은 전체 시퀀스에 대해 두 단계로 진행한다:
 *   1.  PREFIX 단계: 각 GROUP에 대해, 지금까지 남겨 둔 마지막 N개의
 *      survivor를 GROUP의 children과 비교한다.  일치하면 그것들을 버리고
 *      GROUP의 min/max를 늘린다.  더 이상 일치하지 않을 때까지 반복한다.
 *   2.  SUFFIX 단계: 각 GROUP에 대해, 아직 읽지 않은 다음 N개의 요소를
 *      GROUP의 children과 비교한다.  일치하면 이들을 건너뛰고 min/max를
 *      늘린다.  더 이상 일치하지 않을 때까지 반복한다.
 *
 * 예:
 *   A B (A B)+ -> (A B){2,}
 *   (A B)+ A B -> (A B){2,}
 *   A B (A B)+ A B -> (A B){3,}
 *
 * 두 단계가 똑같이 안전한 것은 아니다.  prefix 사본은 필수이며 그룹 앞에
 * 오는데, 이는 그 사본이 되는 선행 필수 반복과 정확히 같은 자리이므로,
 * 어떤 내용에 대해서도 결정 트리가 동형으로 유지된다.  suffix 사본은
 * 그룹이 멈추기로 이미 결정한 뒤에 오는데, 병합된 형태는 이를 마지막
 * 반복 자체의 선택 뒤로 미룬다.  suffix는 내용이 고정된 수의 행을
 * 소비할 때만 병합한다. 그래야 결정할 것이 남지 않기 때문이다;
 * 이 조건이 맞는 이유는 mergeConsecutiveGroups 를 참고하라.
 */
static List *
mergeGroupPrefixSuffix(List *children)
{
	int			numChildren;
	int			writepos;
	int			readpos;

	/*
	 * PREFIX 단계.  GROUP 바로 앞에 놓인 모든 사본은, 어떤 suffix를 고려하기
	 * 전에 전체 시퀀스에 걸쳐 그 GROUP에 접혀 들어간다.  두 GROUP 사이의
	 * 사본은 앞 GROUP의 suffix이면서 뒤 GROUP의 prefix인데, 이 순서는 그것을
	 * 둘 중 더 안전한 규칙인 뒤쪽에 넘긴다: 그룹 앞의 필수 사본은 이미 그것이
	 * 되는 선행 반복이 있을 자리에 있으므로, prefix로 접는 것은 어떤 내용에도
	 * 성립하는 반면, suffix로 접는 것은 고정 길이 본문을 필요로 한다.
	 *
	 * prefix 사본은 이미 저장된 survivor 중 하나이므로, 이를 접는 것은 write
	 * 커서를 한 칸 뒤로 되돌리는 것이다.
	 */
	writepos = 0;
	numChildren = list_length(children);

	for (readpos = 0; readpos < numChildren; readpos++)
	{
		RPRPatternNode *child = list_nth_node(RPRPatternNode, children, readpos);

		if (child->nodeType == RPR_PATTERN_GROUP && !child->reluctant)
		{
			List	   *content = rprGroupContent(child);
			int			content_len = list_length(content);

			while (rprChildrenMatchAt(children, writepos - content_len, content) &&
				   rprTryAddIteration(child))
				writepos -= content_len;
		}

		/*
		 * 살아남은 것들은 앞으로 압축된다.  writepos는 readpos를
		 * 결코 앞지르지 않으므로, 아직 읽어야 할 셀을 덮어쓸 수 없다.
		 */
		lfirst(list_nth_cell(children, writepos++)) = child;
	}

	children = list_truncate(children, writepos);

	/*
	 * SUFFIX 단계.  suffix 사본은 GROUP이 멈추기로 이미 결정한 뒤에 오는데,
	 * 병합된 형태는 이를 마지막 반복 자체의 선택 뒤로 미루므로, 본문은 고정된
	 * 수의 행을 소비해야 한다; 위 설명 참고.
	 *
	 * 이런 사본은 아직 읽지 않은 상태이므로, 이를 접는 것은 read 커서를 한 칸
	 * 앞으로 내보내는 것이다.
	 */
	writepos = 0;
	readpos = 0;
	numChildren = list_length(children);

	while (readpos < numChildren)
	{
		RPRPatternNode *child = list_nth_node(RPRPatternNode, children, readpos);
		int			runlen = 1;

		if (child->nodeType == RPR_PATTERN_GROUP && !child->reluctant)
		{
			List	   *content = rprGroupContent(child);
			int			content_len = list_length(content);

			while (rprBodyHasUniformLength(content) &&
				   rprChildrenMatchAt(children, readpos + runlen, content) &&
				   rprTryAddIteration(child))
				runlen += content_len;
		}

		lfirst(list_nth_cell(children, writepos++)) = child;
		readpos += runlen;
	}

	return list_truncate(children, writepos);
}

/*
 * optimizeSeqPattern
 *		SEQ 패턴 노드를 최적화한다.
 *
 * 최적화는 다음 순서로 실행된다:
 *   1. children을 재귀적으로 최적화하고 중첩된 SEQ를 평탄화한다
 *   2. 연속으로 동일한 VAR 노드를 병합한다
 *   3. 연속으로 동일한 GROUP 노드를 병합한다
 *   4. 연속으로 동일한 ALT 노드를 GROUP으로 병합한다
 *   5. prefix/suffix를 일치하는 children을 가진 GROUP으로 병합한다
 *   6. 연속으로 동일한 GROUP 노드를 한 번 더 병합한다
 *   7. 단일 항목 SEQ를 푼다
 *
 * 이 순서에는 의미가 있다: 1 은 children을 최적화하므로,
 * 그 뒤의 모든 단계는 완성된 노드로 이루어진 평평한 리스트를
 * 보게 되며, 6 은 아래에 나오는 이유로 실행된다.
 */
static RPRPatternNode *
optimizeSeqPattern(RPRPatternNode *pattern)
{
	pattern->children = flattenSeqChildren(pattern->children);
	pattern->children = mergeConsecutiveVars(pattern->children);
	pattern->children = mergeConsecutiveGroups(pattern->children);
	pattern->children = mergeConsecutiveAlts(pattern->children);
	pattern->children = mergeGroupPrefixSuffix(pattern->children);

	/*
	 * 서로 나란히 놓이게 만든 것이 없어도 동일한 두 GROUP이 이웃하게 될 수
	 * 있다: ALT 병합은 하나의 구간을 GROUP으로 감싸는데 이것이 동일한 GROUP
	 * 옆에 놓일 수 있고, prefix나 suffix를 접어 넣으면 두 GROUP 사이의 틈이
	 * 닫힐 수 있다.  그래서 GROUP 병합을 한 번 더 살펴본다.  한 번이면
	 * 충분하다: 이 단계는 요소를 없애고 수량자를 늘릴 뿐이므로, prefix/suffix
	 * 단계가 다시 접어 넣을 사본을 만들어 내지 않는다.
	 */
	pattern->children = mergeConsecutiveGroups(pattern->children);

	/* 단일 항목 SEQ를 푼다: SEQ[A] -> A */
	if (list_length(pattern->children) == 1)
		return (RPRPatternNode *) linitial(pattern->children);

	return pattern;
}

/*
 * flattenAltChildren
 *		children을 재귀적으로 최적화하고 중첩된 ALT 노드를 평탄화한다.
 *
 * 예:
 *   (A | (B | C)) -> (A | B | C)
 *
 * 중첩된 각 ALT의 children을, 그 ALT가 있던 위치에 부모 리스트로 이어 붙여서,
 * 평탄화된 alternative들이 자기 자리를 유지하게 한다.  flattenSeqChildren()과
 * 마찬가지로, 이 단계도 시작했을 때보다 길어질 수 있으므로 가진 셀을 압축하는
 * 대신 새 리스트를 만든다; 호출자는 결과를 대입해야 한다.
 */
static List *
flattenAltChildren(List *children)
{
	List	   *flattened = NIL;

	foreach_node(RPRPatternNode, child, children)
	{
		RPRPatternNode *optimized = optimizeRPRPattern(child);

		if (optimized->nodeType == RPR_PATTERN_ALT)
			flattened = list_concat(flattened, optimized->children);
		else
			flattened = lappend(flattened, optimized);
	}

	return flattened;
}

/*
 * removeDuplicateAlternatives
 *		리스트에서 중복된 alternative를 제거한다.
 *
 * 예:
 *   (A | B | A) -> (A | B)
 *   (X | Y | X | Z | Y) -> (X | Y | Z)
 *
 * 각각의 첫 등장만 남기고, 주어진 리스트의 앞쪽으로 survivor를 압축하므로,
 * 호출자는 잘라낸 결과를 대입해야 한다.
 */
static List *
removeDuplicateAlternatives(List *children)
{
	int			writepos = 0;

	for (int readpos = 0; readpos < list_length(children); readpos++)
	{
		RPRPatternNode *node = list_nth_node(RPRPatternNode, children, readpos);
		bool		isDuplicate = false;

		/*
		 * survivor는 앞으로 압축되므로, 이미 유지된 것들은 writepos 아래의
		 * 셀에 있다.  writepos는 readpos를 결코 앞지르지 않으므로, 아래로의
		 * 저장이 아직 읽어야 할 셀을 덮어쓸 수 없다.
		 */
		for (int keptpos = 0; keptpos < writepos; keptpos++)
		{
			if (equal(list_nth_node(RPRPatternNode, children, keptpos),
					  node))
			{
				isDuplicate = true;
				break;
			}
		}

		if (!isDuplicate)
			lfirst(list_nth_cell(children, writepos++)) = node;
	}

	return list_truncate(children, writepos);
}

/*
 * optimizeAltPattern
 *		ALT 패턴 노드를 최적화한다.
 *
 * 최적화:
 *   1. 중첩된 ALT를 평탄화한다
 *   2. 중복된 alternative를 제거한다
 *   3. 단일 항목 ALT를 푼다
 */
static RPRPatternNode *
optimizeAltPattern(RPRPatternNode *pattern)
{
	/* children을 재귀적으로 최적화하고 중첩된 ALT를 평탄화한다 */
	pattern->children = flattenAltChildren(pattern->children);

	/* 중복된 alternative를 제거한다 */
	pattern->children = removeDuplicateAlternatives(pattern->children);

	/* 단일 항목 ALT를 푼다: ALT[A] -> A */
	if (list_length(pattern->children) == 1)
		return (RPRPatternNode *) linitial(pattern->children);

	return pattern;
}

/*
 * tryMultiplyQuantifiers
 *		(child{p,q}){m,n}을 child{p*m, q*n}으로 평탄화해 본다.
 *
 * 아래에서 p,q는 자식의 {min,max}이고 m,n은 바깥쪽의 {min,max}이다.
 *
 * 중첩된 수량자들이 만들어 낼 수 있는 반복 횟수가 정확히 연속 구간 [p*m,
 * q*n]을 이룰 때에만 평탄화가 유효하다.  바깥쪽 반복 횟수 t(m <= t <= n)에
 * 대해 자식은 [t*p, t*q]의 어떤 카운트든 낼 수 있고, t = 0 은 {0}을 낸다. 이
 * 구간들의 합집합이 연속되어, 즉 평탄화 가능한 것은 다음일 때다:
 *
 *   - m == n: 바깥쪽 카운트가 하나뿐이므로 결과는 그냥 [m*p, m*q]이다; 또는
 *   - p == 0: 모든 구간이 0 에서 시작하므로 전부 겹친다; 또는
 *   - 연속된 구간들이 맞닿고, (있다면) 0 인 경우가 이어질 때:
 *       p <= Max(m,1)*(q-p) + 1   (맞닿음; q가 무제한이면 자명하게 참)
 *       그리고 (m >= 1 또는 p <= 1) (m == 0 일 때 {0}이 [p,q]에 닿아야 한다)
 *
 * 그렇지 않으면 틈이 생기며 패턴은 평탄화하지 않은 채로 둔다: (A{2}){2,3}은
 * {4,6}을 낳고(4..6 이 아니라), (A{2,})*는 {0} UNION [2,INF)를 낳는다
 * ([0,INF)가 아니라서, 그렇지 않으면 A*가 단 하나의 A도 잘못 허용하게 된다).
 *
 * 연속성은 카운트의 집합을 정할 뿐, 어느 카운트가 선호되는지는 정하지
 * 않으므로, 추가 조건이 필요하다; 아래 safe에 대한 주석을 참고하라.
 *
 * 성공하면 수량자를 곱한 자식 노드를 반환하고, 그렇지 않으면 원래 패턴을
 * 그대로 반환한다.
 */
static RPRPatternNode *
tryMultiplyQuantifiers(RPRPatternNode *pattern)
{
	RPRPatternNode *child;
	bool		safe;
	int32		newmin;
	int32		newmax;

	/* 파서는 항상 자식이 정확히 하나인 GROUP을 만든다 */
	Assert(list_length(pattern->children) == 1);

	if (pattern->reluctant)
		return pattern;

	child = (RPRPatternNode *) linitial(pattern->children);

	if ((child->nodeType != RPR_PATTERN_VAR &&
		 child->nodeType != RPR_PATTERN_GROUP) ||
		child->reluctant)
		return pattern;

	/*
	 * 평탄화는 바깥쪽 블록 경계를 지우므로, 자식의 반복이 블록 사이에 어떻게
	 * 나뉘는지는 문제가 되지 않아야 한다.  고정 길이 본문은 이를 보장한다 --
	 * 총 길이가 같은 분할은 같은 행에 이르므로 -- 정확한 자식 수량자도
	 * 마찬가지인데, 이는 오직 하나의 분할만 허용하기 때문이다.  그렇지 않으면
	 * 선호가 바뀐다: ((A | B B){1,2}){2}는 (A | B B){2,4}가 되는데, 중첩된
	 * 형태가 A (B B) A A를 선호하는 자리에서 A 두 개로 멈춘다.
	 *
	 * VAR 자식은 측정할 본문이 없고 자신의 수량자가 이미 이를 결정하므로, 이
	 * 검사는 GROUP 자식에만 적용한다.
	 */
	if (child->min != child->max &&
		child->nodeType == RPR_PATTERN_GROUP &&
		!rprBodyHasUniformLength(child->children))
		return pattern;

	/*
	 * 달성 가능한 카운트들이 하나의 연속 구간을 이루는지 판단한다.  자식
	 * 수량자는 {child->min, child->max}이고 바깥쪽 수량자는 {pattern->min,
	 * pattern->max}이며, 둘 중 어느 max도 RPR_QUANTITY_INF 일 수 있다.
	 */
	if (pattern->min == pattern->max || child->min == 0)
		safe = true;
	else
	{
		bool		touch;
		bool		zero_ok;
		bool		order_ok;

		/*
		 * 연속된 구간 [t*min, t*max]와 [(t+1)*min, (t+1)*max]는 (t+1)*min <=
		 * t*max + 1, 즉 min <= t*(max-min) + 1 일 때 맞닿는다.  이는 진행
		 * 중인 가장 작은 t, 즉 Max(pattern->min, 1)에서 가장 타이트하다.
		 * 자식의 max가 무제한이면 모든 구간이 INF에 이르므로 항상 맞닿는다.
		 */
		if (child->max == RPR_QUANTITY_INF)
			touch = true;
		else
			touch = ((int64) child->min <=
					 (int64) Max(pattern->min, 1) * (child->max - child->min) + 1);

		/*
		 * 스킵 가능한 바깥쪽(min 0)은 {0}이 자식 범위에 인접할 것도
		 * 필요로 한다.
		 */
		zero_ok = (pattern->min >= 1 || child->min <= 1);

		/*
		 * 연속성은 필요조건이지만 충분조건은 아니다: 평탄화된 형태도 같은
		 * 매치를 선호해야 한다.  중첩된 형태는 다시 반복하기 전에 첫 반복의
		 * 카운트를 먼저 정하므로, 꼬리가 자식의 하한에 이를 수 없을 때 일찍
		 * 멈춘다 -- (A{2,3}){1,2}는 평탄화된 A{2,6}이 네 행을 취하는 자리에서
		 * 세 행을 선호한다.  하한이 2 이상으로 제한된 경우만 이렇게 미달할
		 * 수 있다.
		 */
		order_ok = (child->min <= 1 || child->max == RPR_QUANTITY_INF);

		safe = touch && zero_ok && order_ok;
	}

	if (!safe)
		return pattern;

	/* 자식 수량자를 평탄화하며, 맞지 않으면 재작성을 포기한다 */
	if (pg_mul_s32_overflow(pattern->min, child->min, &newmin) ||
		newmin >= RPR_QUANTITY_INF)
		return pattern;

	/*
	 * RPR_QUANTITY_INF 는 카운트가 아니라 무제한을 의미한다: 그 값에 도달하는
	 * 유한한 곱은 표현 가능하므로, 따로 거부한다.
	 */
	if (pattern->max == RPR_QUANTITY_INF || child->max == RPR_QUANTITY_INF)
		newmax = RPR_QUANTITY_INF;
	else if (pg_mul_s32_overflow(pattern->max, child->max, &newmax) ||
			 newmax >= RPR_QUANTITY_INF)
		return pattern;

	child->min = newmin;
	child->max = newmax;
	return child;
}

/*
 * tryUnwrapGroup
 *		GROUP{1,1} 노드를 풀어 본다.
 *
 * 예:
 *   (A){1,1}   -> A
 *   (A B){1,1} -> SEQ(A, B)  (내부 SEQ를 푼다)
 *   (A)?  -> A?  (단일 VAR 자식에 수량자를 전파) (A)+?  -> A+?
 *   (reluctant를 포함해 수량자를 전파)
 *
 * GROUP이 min=1, max=1 이면 자식을 그대로 반환한다({1,1}에서 reluctant는
 * 의미가 없다).  GROUP이 기본 수량자 {1,1}을 가진 단일 VAR 자식이면, GROUP의
 * 수량자를 자식에 전파하고 푼다.  그 외에는 패턴을 그대로 반환한다.
 *
 * 참고: 파서는 list_make1()로 항상 자식이 정확히 하나인 GROUP을 만든다.
 */
static RPRPatternNode *
tryUnwrapGroup(RPRPatternNode *pattern)
{
	RPRPatternNode *child;

	/* 파서는 항상 자식이 하나인 GROUP을 만든다 */
	Assert(list_length(pattern->children) == 1);

	child = (RPRPatternNode *) linitial(pattern->children);

	/* GROUP{1,1}: 곧바로 푼다({1,1}에서 reluctant는 의미가 없다) */
	if (pattern->min == 1 && pattern->max == 1)
		return child;

	/*
	 * 기본값 {1,1}을 가진 단일 VAR 자식: GROUP의 수량자를 자식에 전파하고
	 * 푼다.  예: (A)??  -> A??, (A)+?  -> A+?
	 */
	if (child->nodeType == RPR_PATTERN_VAR &&
		child->min == 1 && child->max == 1)
	{
		child->min = pattern->min;
		child->max = pattern->max;
		child->reluctant = pattern->reluctant;
		return child;
	}

	return pattern;
}

/*
 * optimizeGroupPattern
 *		GROUP 패턴 노드를 최적화한다.
 *
 * 최적화:
 *   1. 수량자 곱셈: (A{m}){n} -> A{m*n}
 *   2. GROUP{1,1} 풀기
 */
static RPRPatternNode *
optimizeGroupPattern(RPRPatternNode *pattern)
{
	ListCell   *lc;
	RPRPatternNode *result;

	/* children을 재귀적으로 최적화한다 */
	foreach(lc, pattern->children)
	{
		lfirst(lc) = optimizeRPRPattern((RPRPatternNode *) lfirst(lc));
	}

	/* 수량자 곱셈을 시도한다 */
	result = tryMultiplyQuantifiers(pattern);
	if (result != pattern)
		return result;

	/* GROUP{1,1} 풀기를 시도한다 */
	return tryUnwrapGroup(pattern);
}

/*
 * optimizeRPRPattern
 *		RPRPatternNode 트리를 최적화한다(디스패처).
 *
 * 타입별 최적화 함수로 디스패치한다.
 * 최적화된 패턴을 반환한다(다른 노드일 수 있다).
 */
static RPRPatternNode *
optimizeRPRPattern(RPRPatternNode *pattern)
{
	RPRPatternNode *result = pattern;

	/* 파서가 낸 패턴 노드는 결코 NULL이 아니다 */
	Assert(pattern != NULL);

	check_stack_depth();

	/*
	 * 카운트가 고정이면 reluctance가 결정할 것이 남지 않는다.  여기서 없앤다:
	 * 아래의 병합과 곱셈 재작성은 reluctant 노드를 거부하므로, 그렇지 않으면
	 * {n,n}?이 {n,n}이 얻는 것을 놓치게 된다.
	 */
	if (pattern->min == pattern->max)
		pattern->reluctant = false;

	switch (pattern->nodeType)
	{
		case RPR_PATTERN_VAR:
			break;
		case RPR_PATTERN_SEQ:
			result = optimizeSeqPattern(pattern);
			break;
		case RPR_PATTERN_ALT:
			result = optimizeAltPattern(pattern);
			break;
		case RPR_PATTERN_GROUP:
			result = optimizeGroupPattern(pattern);
			break;
	}

	/* 다시: 재작성이 그 자체로 고정 카운트를 만들어 냈을 수 있다 */
	if (result->min == result->max)
		result->reluctant = false;

	return result;
}

/*
 * scanRPRPatternRecursive
 *		패턴 파스 트리를 재귀적으로 스캔한다(패스 1 내부용).
 *
 * 고유한 변수 이름을 모으고 요소 수를 세면서 depth를
 * 추적한다.  DEFINE 절의 변수는 이미 varNames 에 있으므로,
 * 이 함수는 패턴에서 발견한 추가 변수만 덧붙인다.
 */
static void
scanRPRPatternRecursive(RPRPatternNode *node, char **varNames, int *numVars,
						int *numElements, RPRDepth depth, RPRDepth *maxDepth)
{
	int			i;

	/* 파서가 낸 패턴 노드는 결코 NULL이 아니다 */
	Assert(node != NULL);

	check_stack_depth();

	/* 오버플로가 나기 전에 재귀 depth 한계를 확인한다 */
	if (depth >= RPR_DEPTH_MAX)
		ereport(ERROR,
				errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				errmsg("pattern nesting too deep"),
				errdetail("Pattern nesting depth %d exceeds maximum %d.",
						  depth, RPR_DEPTH_MAX - 1));

	/* 최대 depth를 추적한다 */
	*maxDepth = Max(*maxDepth, depth);

	switch (node->nodeType)
	{
		case RPR_PATTERN_VAR:
			/* 요소를 센다 */
			(*numElements)++;

			/* 아직 없다면 변수 이름을 모은다 */
			for (i = 0; i < *numVars; i++)
			{
				if (strcmp(varNames[i], node->varName) == 0)
					return;		/* 이미 이 변수를 가지고 있다 */
			}

			/*
			 * DEFINE 절에 없는 변수 - ISO/IEC 19075-5 Feature R020에 따라
			 * 유효하다.  이런 변수는 암묵적으로 TRUE이다.  varNames 에
			 * 추가해서, DEFINE 절 표현식 개수 이상의 varId 를 받게 하며,
			 * 실행기는 이를 TRUE로 취급한다.
			 */
			Assert(*numVars <= RPR_VARID_MAX);
			varNames[(*numVars)++] = node->varName;
			break;

		case RPR_PATTERN_SEQ:
			/* 시퀀스: children으로 그냥 재귀한다 */
			foreach_node(RPRPatternNode, child, node->children)
			{
				scanRPRPatternRecursive(child, varNames,
										numVars, numElements, depth, maxDepth);
			}
			break;

		case RPR_PATTERN_GROUP:

			/*
			 * 그룹의 수량자가 사소하지 않으면(즉 {1,1}이 아니면)
			 * BEGIN 요소를 추가한다
			 */
			if (node->min != 1 || node->max != 1)
				(*numElements)++;

			/* depth를 늘려 children으로 재귀한다 */
			foreach_node(RPRPatternNode, child, node->children)
			{
				scanRPRPatternRecursive(child, varNames,
										numVars, numElements, depth + 1, maxDepth);
			}

			/*
			 * 그룹의 수량자가 사소하지 않으면({1,1}이 아니면)
			 * END 요소를 추가한다
			 */
			if (node->min != 1 || node->max != 1)
				(*numElements)++;
			break;

		case RPR_PATTERN_ALT:
			/* ALT 시작 요소를 센다 */
			(*numElements)++;

			/* depth를 늘려 children으로 재귀한다 */
			foreach_node(RPRPatternNode, child, node->children)
			{
				/* 각 분기는 SEP 분기-구분자 마커로 끝난다 */
				(*numElements)++;
				scanRPRPatternRecursive(child, varNames,
										numVars, numElements, depth + 1, maxDepth);
			}
			break;
	}
}

/*
 * scanRPRPattern
 *		패턴 파스 트리를 스캔한다(패스 1 진입점).
 *
 * (DEFINE 절에서 온 것에 이어) 고유한 변수 이름을 모으고, (FIN 마커를 포함해)
 * 전체 요소 수를 세고, 최대 depth를 추적한다.  요소 수가 RPR_ELEMIDX_MAX 를
 * 넘으면 오류를 보고한다.
 */
static void
scanRPRPattern(RPRPatternNode *node, char **varNames, int *numVars,
			   int *numElements, RPRDepth *maxDepth)
{
	*numElements = 0;
	*maxDepth = 0;

	scanRPRPatternRecursive(node, varNames, numVars, numElements, 0, maxDepth);

	(*numElements)++;			/* FIN 마커를 위한 +1 */

	if (*numElements > RPR_ELEMIDX_MAX)
		ereport(ERROR,
				errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				errmsg("pattern too complex"),
				errdetail("Pattern has %d elements, maximum is %d.",
						  *numElements, RPR_ELEMIDX_MAX));
}

/*
 * makeRPRPattern
 *		RPRPattern 구조체를 할당하고 초기화한다.
 *
 * 패턴 구조체를 만들고, 변수 이름을 복사하고, elements 배열을 할당한다.
 * elements 배열은 0 으로 초기화된다.
 */
static RPRPattern *
makeRPRPattern(int numVars, int numElements, RPRDepth maxDepth,
			   char **varNamesStack)
{
	RPRPattern *result;
	int			i;

	result = makeNode(RPRPattern);
	result->numVars = numVars;

	/*
	 * depth < RPR_DEPTH_MAX 이므로,
	 * maxDepth + 1 은 RPR_DEPTH_MAX 를 넘지 않는다.
	 */
	Assert(maxDepth < RPR_DEPTH_MAX);
	result->maxDepth = maxDepth + 1;	/* +1: depth는 0 부터 시작한다 */
	result->numElements = numElements;

	/* varNames 를 복사한다(패턴은 변수를 적어도 하나 가져야 한다) */
	Assert(numVars > 0);
	result->varNames = palloc_array(char *, numVars);
	for (i = 0; i < numVars; i++)
		result->varNames[i] = pstrdup(varNamesStack[i]);

	/* elements 배열을 할당한다(예약 필드를 위해 0 으로 초기화) */
	Assert(numElements >= 2);
	result->elements = palloc0_array(RPRPatternElement, numElements);

	return result;
}

/*
 * getVarIdFromPattern
 *		RPRPattern에서 변수 이름에 대한 변수 ID를 구한다.
 *
 * varNames 배열에서 그 변수의 인덱스를 반환한다.
 */
static RPRVarId
getVarIdFromPattern(RPRPattern *pat, const char *varName)
{
	for (int i = 0; i < pat->numVars; i++)
	{
		if (strcmp(pat->varNames[i], varName) == 0)
			return (RPRVarId) i;
	}

	/* 일어나면 안 된다 - 변수는 이미 수집되어 있어야 한다 */
	elog(ERROR, "pattern variable \"%s\" not found", varName);
	pg_unreachable();
}

/*
 * fillRPRPatternVar
 *		VAR 패턴 요소를 채운다.
 *
 * 이 VAR에 대한 빈-매치 플래그를 반환한다:
 * nullable이면(min 0 이라서 0 개 행에 매치할 수 있으면)
 * RPR_ELEM_EMPTY_LOOP 를, 선호하는 도출이 빈 것이면
 * RPR_ELEM_EMPTY_PREFERRED 를 추가로 반환한다.  단독 변수는 한 행을 소비한다;
 * 0 회 반복을 취할 수 있는 reluctant 수량자만 건너뛰는 쪽을 선호한다.
 */
static RPRElemFlags
fillRPRPatternVar(RPRPatternNode *node, RPRPattern *pat, int *idx, RPRDepth depth)
{
	RPRPatternElement *elem = &pat->elements[*idx];
	RPRElemFlags flags = 0;

	memset(elem, 0, sizeof(RPRPatternElement));
	elem->varId = getVarIdFromPattern(pat, node->varName);
	elem->depth = depth;
	elem->min = node->min;
	elem->max = node->max;
	Assert(elem->min >= 0 && elem->min < RPR_QUANTITY_INF &&
		   elem->max >= 1 && elem->min <= elem->max);
	elem->next = RPR_ELEMIDX_INVALID;
	elem->jump = RPR_ELEMIDX_INVALID;
	if (node->reluctant)
		elem->flags |= RPR_ELEM_RELUCTANT;
	(*idx)++;

	if (node->min == 0)
	{
		/* nullable이다; reluctant 수량자는 빈 매치도 선호한다 */
		flags |= RPR_ELEM_EMPTY_LOOP;
		if (node->reluctant)
			flags |= RPR_ELEM_EMPTY_PREFERRED;
	}
	return flags;
}

/*
 * fillRPRPatternGroup
 *		GROUP 패턴과 그 children을 채운다.
 *
 * depth를 늘려 그룹 내용에 대한 요소들을 만들고, 그룹의 수량자가 사소하지
 * 않으면({1,1}이 아니면) BEGIN/END 마커 쌍을 추가한다.
 *
 * (A B){2,3}에 대한 요소 배치:
 *
 *   [BEGIN]  [A]  [B]  [END]  [다음 요소...]
 *     |       ^           | |       ^
 *     |       +-- jump ---+ +-next--+ (END.jump: 첫 자식으로 되돌아가는
 *     +------- jump ------^           루프)
 *                                     (BEGIN.jump: 이 그룹의 END)
 *
 * BEGIN.jump는 그룹 자신의 END를 가리키므로, 어느 마커에서든
 * 한 번에 다른 쪽을 찾을 수 있다.  min == 0 일 때 택하는 스킵
 * 경로는 END에 도달하지 않고 END.next를 통해 빠져나간다: 카운트는
 * 거기서만 검사하므로, BEGIN은 max에 도달하기 위한 스킵을
 * 취하지 않는다.  END.jump는 첫 자식을 가리킨다(루프백 경로).
 * BEGIN.next와 END.next는 나중에 finalizeRPRPattern()이 설정한다.
 *
 * 그룹의 빈-매치 플래그를 반환한다.  그룹이 nullable이면(min이 0
 * 이어서 완전히 건너뛸 수 있거나 본문이 nullable이면, 즉 본문을 지나는
 * 모든 경로가 0 개 행에 매치할 수 있으면) RPR_ELEM_EMPTY_LOOP 를
 * 설정한다.  그룹이 선호하는 도출이 빈 것이면(min이 0 인 reluctant 그룹은
 * 반복을 취하지 않는 쪽을 선호하고, 그 외에는 그룹이 본문을 따른다)
 * RPR_ELEM_EMPTY_PREFERRED 를 설정한다.  END 요소는 본문의 비트를 물려받는다.
 */
static RPRElemFlags
fillRPRPatternGroup(RPRPatternNode *node, RPRPattern *pat, int *idx, RPRDepth depth)
{
	int			groupStartIdx = *idx;
	int			beginIdx = -1;
	RPRElemFlags bodyFlags = RPR_ELEM_EMPTY_LOOP | RPR_ELEM_EMPTY_PREFERRED;
	RPRElemFlags result;

	/* 그룹의 수량자가 사소하지 않으면({1,1}이 아니면) BEGIN 마커를 추가한다 */
	if (node->min != 1 || node->max != 1)
	{
		RPRPatternElement *elem = &pat->elements[*idx];

		beginIdx = *idx;
		memset(elem, 0, sizeof(RPRPatternElement));
		elem->varId = RPR_VARID_BEGIN;
		elem->depth = depth;
		elem->min = node->min;
		elem->max = node->max;
		Assert(elem->min >= 0 && elem->min < RPR_QUANTITY_INF &&
			   elem->max >= 1 && elem->min <= elem->max);
		elem->next = RPR_ELEMIDX_INVALID;	/* finalize에서 설정 */
		elem->jump = RPR_ELEMIDX_INVALID;	/* END 뒤에 설정 */
		if (node->reluctant)
			elem->flags |= RPR_ELEM_RELUCTANT;
		(*idx)++;
		groupStartIdx = *idx;	/* children은 BEGIN 다음부터 시작한다 */
	}

	/*
	 * concatenation은 모든 자식이 그럴
	 * 때에만(AND) nullable / empty-preferred이다
	 */
	foreach_node(RPRPatternNode, child, node->children)
		bodyFlags &= fillRPRPattern(child, pat, idx, depth + 1);

	/*
	 * 그룹의 수량자가 사소하지 않으면({1,1}이 아니면) 그룹 끝 마커를 추가한다
	 */
	if (node->min != 1 || node->max != 1)
	{
		RPRPatternElement *beginElem = &pat->elements[beginIdx];
		RPRPatternElement *endElem = &pat->elements[*idx];

		memset(endElem, 0, sizeof(RPRPatternElement));
		endElem->varId = RPR_VARID_END;
		endElem->depth = depth;
		endElem->min = node->min;
		endElem->max = node->max;
		Assert(endElem->min >= 0 && endElem->min < RPR_QUANTITY_INF &&
			   endElem->max >= 1 && endElem->min <= endElem->max);
		endElem->next = RPR_ELEMIDX_INVALID;
		endElem->jump = groupStartIdx;	/* 첫 자식으로 루프 */
		if (node->reluctant)
			endElem->flags |= RPR_ELEM_RELUCTANT;

		/* END는 그룹이 아니라 본문의 비트를 물려받는다; README V-6 참고 */
		endElem->flags |= bodyFlags;

		/* BEGIN의 링크를 그 END로 설정한다(next는 finalize가 설정) */
		beginElem->jump = *idx;

		(*idx)++;
	}

	result = bodyFlags;
	if (node->min == 0)
	{
		/* 완전히 스킵 가능하다; reluctant면 그룹은 스킵을 선호한다 */
		result |= RPR_ELEM_EMPTY_LOOP;
		if (node->reluctant)
			result |= RPR_ELEM_EMPTY_PREFERRED;
	}
	return result;
}

/*
 * fillRPRPatternAlt
 *		ALT 패턴과 그 alternative들을 채운다.
 *
 * ALT 마커를 만들고 depth를 늘려 각 alternative를 채우며, (마지막을 포함해)
 * 모든 alternative를 SEP 분기-구분자 마커로 끝맺는다.  분기 링크는 ALT에서
 * SEP 체인을 통해 이어지며, 분기 내용을 통하지는 않는다: 분기의 첫 요소가
 * 그 자체로 그룹 BEGIN일 수 있는데, 이때 jump는 그 그룹의 END이다.
 *
 *   ALT.next  -> 첫 분기 내용          SEP.next -> 다음 분기 내용
 *   ALT.jump  -> 첫 SEP                          (마지막 분기에서는
 *                                                 ALT 다음)
 *   SEP.jump  -> 다음 SEP (마지막에서는 -1)
 *
 * SEP는 마커일 뿐 상태가 아니다: 각 분기의 꼬리는 alternation을 지나
 * 재지정된다.  분기 말단인 그룹의 BEGIN 스킵은 그룹의 END를 통해 빠져나가는데
 * 그것이 곧 그 분기의 꼬리이므로, 따로 재지정할 필요가 없다.
 *
 * alternation의 빈-매치 플래그를 반환한다.  어느 한 분기라도 nullable이면(OR:
 * 하나의 nullable 분기로 충분하다) RPR_ELEM_EMPTY_LOOP 를 설정한다.
 * RPR_ELEM_EMPTY_PREFERRED 는 첫 분기만 따른다: 사전식 순서가 그것을 선호되는
 * 분기로 만들므로, 이후 분기들이 빈 것을 선호하는지는 중요하지 않다.
 */
static RPRElemFlags
fillRPRPatternAlt(RPRPatternNode *node, RPRPattern *pat, int *idx, RPRDepth depth)
{
	ListCell   *lc;
	ListCell   *lc2;
	RPRPatternElement *elem;
	int			altIdx = *idx;
	List	   *altBranchStarts = NIL;
	List	   *altEndPositions = NIL;
	int			afterAltIdx;
	RPRElemFlags altFlags = 0;	/* 분기 EMPTY_LOOP 비트들의 OR */
	RPRElemFlags firstFlags = 0;	/* 첫 분기의 플래그
									 * (EMPTY_PREFERRED 용) */
	bool		firstBranch = true;

	/* alternation 시작 마커를 추가한다 */
	elem = &pat->elements[*idx];
	memset(elem, 0, sizeof(RPRPatternElement));
	elem->varId = RPR_VARID_ALT;
	elem->depth = depth;
	elem->min = 1;
	elem->max = 1;
	elem->next = RPR_ELEMIDX_INVALID;
	elem->jump = RPR_ELEMIDX_INVALID;
	(*idx)++;

	/* ALT는 첫 분기 내용으로 들어간다(바로 다음 요소) */
	pat->elements[altIdx].next = *idx;

	/* 각 alternative를 채우고, SEP 분기-구분자 마커로 끝맺는다 */
	foreach_node(RPRPatternNode, alt, node->children)
	{
		int			branchStart = *idx;
		RPRPatternElement *sep;
		RPRElemFlags branchFlags;

		altBranchStarts = lappend_int(altBranchStarts, branchStart);
		branchFlags = fillRPRPattern(alt, pat, idx, depth + 1);

		/*
		 * 어느 분기든 nullable이면 nullable이다;
		 * empty-preferred는 첫 분기 기준
		 */
		altFlags |= (branchFlags & RPR_ELEM_EMPTY_LOOP);
		if (firstBranch)
		{
			firstFlags = branchFlags;
			firstBranch = false;
		}
		altEndPositions = lappend_int(altEndPositions, *idx - 1);

		/* SEP가 이 분기를 끝맺으므로, 분기 끝 + 1 에 위치한다 */
		sep = &pat->elements[*idx];
		memset(sep, 0, sizeof(RPRPatternElement));
		sep->varId = RPR_VARID_SEP;
		sep->depth = depth;		/* 분기 수준이 아니라 ALT 수준 경계 */
		sep->min = 1;
		sep->max = 1;
		sep->next = RPR_ELEMIDX_INVALID;
		sep->jump = RPR_ELEMIDX_INVALID;
		(*idx)++;
	}

	afterAltIdx = *idx;

	/* ALT는 첫 분기를 끝맺는 SEP에 도달한다 */
	pat->elements[altIdx].jump = linitial_int(altEndPositions) + 1;

	/*
	 * SEP 체인을 연결하고, 각 분기의 출구를 alternation 뒤로 재지정한다.
	 */
	forboth(lc, altBranchStarts, lc2, altEndPositions)
	{
		int			branchStart = lfirst_int(lc);
		int			endPos = lfirst_int(lc2);
		int			sepIdx = endPos + 1;
		ListCell   *nextEnd = lnext(altEndPositions, lc2);
		int			elemIdx;

		/* SEP.jump -> 다음 SEP; SEP.next -> 다음 분기 내용 */
		if (nextEnd != NULL)
		{
			pat->elements[sepIdx].jump = lfirst_int(nextEnd) + 1;
			pat->elements[sepIdx].next = lfirst_int(lnext(altBranchStarts, lc));
		}
		else
		{
			pat->elements[sepIdx].jump = RPR_ELEMIDX_INVALID;
			pat->elements[sepIdx].next = afterAltIdx;
		}

		/*
		 * 분기의 자연스러운 출구를 alternation 뒤로 재지정한다.  자연스러운
		 * 출구는 분기 내용 다음 요소, 즉 이 분기의 SEP인데, 단순한 꼬리는
		 * next를 설정하지 않은 채로 두고(finalize가 SEP로 흘려보낸다), 내부
		 * ALT는 이미 next를 그 위치로 설정해 두었다.
		 */
		if (pat->elements[endPos].next != RPR_ELEMIDX_INVALID)
		{
			int			oldTarget = pat->elements[endPos].next;

			for (elemIdx = branchStart; elemIdx <= endPos; elemIdx++)
			{
				if (pat->elements[elemIdx].next == oldTarget)
					pat->elements[elemIdx].next = afterAltIdx;
			}
		}
		else
		{
			pat->elements[endPos].next = afterAltIdx;
		}

	}

	list_free(altBranchStarts);
	list_free(altEndPositions);

	return altFlags | (firstFlags & RPR_ELEM_EMPTY_PREFERRED);
}

/*
 * fillRPRPattern
 *		파스 트리로부터 요소 배열을 채운다(패스 2).
 *
 * 파스 트리를 재귀적으로 순회하며 미리 할당된 elements 배열을 채운다.  타입별
 * 채우기 함수로 디스패치한다.
 *
 * 패턴의 빈-매치 플래그를 반환한다(nullable이면 RPR_ELEM_EMPTY_LOOP,
 * empty-preferred이면 RPR_ELEM_EMPTY_PREFERRED).
 * SEQ에서는 모든 자식이 그럴 때에만 concatenation이
 * nullable / empty-preferred이므로, 자식들의 플래그를 AND한다.
 */
static RPRElemFlags
fillRPRPattern(RPRPatternNode *node, RPRPattern *pat, int *idx, RPRDepth depth)
{
	/* 파서가 낸 패턴 노드는 결코 NULL이 아니다 */
	Assert(node != NULL);

	check_stack_depth();

	switch (node->nodeType)
	{
		case RPR_PATTERN_SEQ:
			{
				RPRElemFlags flags = RPR_ELEM_EMPTY_LOOP | RPR_ELEM_EMPTY_PREFERRED;

				foreach_node(RPRPatternNode, child, node->children)
					flags &= fillRPRPattern(child, pat, idx, depth);
				return flags;
			}

		case RPR_PATTERN_VAR:
			return fillRPRPatternVar(node, pat, idx, depth);

		case RPR_PATTERN_GROUP:
			return fillRPRPatternGroup(node, pat, idx, depth);

		case RPR_PATTERN_ALT:
			return fillRPRPatternAlt(node, pat, idx, depth);
	}

	pg_unreachable();
	return 0;
}

/*
 * finalizeRPRPattern
 *		요소를 채운 뒤 패턴 구조체를 마무리한다.
 *
 * 이 함수가 하는 일:
 *   1. 흡수 플래그를 false로 초기화
 *   2. 순차 흐름을 위한 next 포인터 설정
 *   3. 끝에 FIN 마커 추가
 */
static void
finalizeRPRPattern(RPRPattern *result)
{
	int			finIdx = result->numElements - 1;
	int			i;
	RPRPatternElement *finElem;

	/* 흡수 플래그를 초기화한다 */
	result->isAbsorbable = false;

	/* next가 없는 요소들의 next 포인터를 설정한다 */
	for (i = 0; i < finIdx; i++)
	{
		RPRPatternElement *elem = &result->elements[i];

		if (elem->next == RPR_ELEMIDX_INVALID)
			elem->next = (i < finIdx - 1) ? i + 1 : finIdx;

		/* 수량자 범위가 유효한지 검증한다 */
		Assert(elem->min >= 0 && elem->min < RPR_QUANTITY_INF &&
			   elem->max >= 1 && elem->min <= elem->max);
	}

	/* 끝에 FIN 마커를 추가한다 */
	finElem = &result->elements[finIdx];
	memset(finElem, 0, sizeof(RPRPatternElement));
	finElem->varId = RPR_VARID_FIN;
	finElem->depth = 0;
	finElem->min = 1;
	finElem->max = 1;
	finElem->next = RPR_ELEMIDX_INVALID;
	finElem->jump = RPR_ELEMIDX_INVALID;
}

/*-------------------------------------------------------------------------
 * 컨텍스트 흡수: 2-플래그 설계
 *-------------------------------------------------------------------------
 *
 * 컨텍스트 흡수는 더 오래된 컨텍스트보다 긴 매치를 만들어 낼 수 없는 더 최근
 * 컨텍스트를 흡수하여 불필요한 매치 탐색을 없앤다.  이는 A+ B와 같은 패턴에서
 * O(n^2) -> O(n) 성능 향상을 달성한다.
 *
 * 핵심 통찰:
 *   패턴 A+ B에 대해, Ctx1이 0 행에서 시작하고 Ctx2가 1 행에서 시작하여 둘 다
 *   A에 계속 매치한다면, Ctx1은 항상 더 많은 A 매치를 가진다.  B가 마침내
 *   나타나면, Ctx1의 매치(0 에서 현재까지)는 항상 Ctx2의
 *   매치(1 에서 현재까지)보다 길다.  그러므로 Ctx2는 안전하게 제거할 수 있다.
 *
 * 두 플래그:
 *   1. RPR_ELEM_ABSORBABLE - "Absorption comparison point"
 *      흡수를 위해 컨텍스트를 비교할 수 있는 위치.
 *      - 단순 무제한 VAR(A+): VAR 요소 자신
 *      - 무제한 GROUP((A B)+): END 요소만
 *
 *   2. RPR_ELEM_ABSORBABLE_BRANCH - "Absorbable region marker"
 *      흡수 가능 영역 안의 모든 요소.
 *      - 런타임에 state.isAbsorbable 을 추적하는 데 사용
 *      - 이 영역을 벗어난 상태는 영구히 흡수 불가가 된다
 *
 * 왜 두 개의 플래그인가?
 *   패턴 "(A B)+"에서는, (하나는 A에, 다른 하나는 B에 있는) 서로 다른 위치의
 *   컨텍스트를 비교할 수 없다 - 반드시 END에서 동기화해야 한다.
 *
 *   예: 입력 A B A B A B...에 대한 "(A B)+"
 *     0 행 (A): Ctx1이 시작해 A에 매치
 *     1 행 (B): Ctx1이 B에 매치 -> END (count=1)
 *     2 행 (A): Ctx1이 A로 루프, Ctx2가 A에서 시작
 *     3 행 (B): Ctx1은 END(count=2), Ctx2는 END(count=1)
 *                -> 둘 다 END에 있어 비교 가능! Ctx1이 Ctx2를 흡수한다.
 *
 *   컨텍스트는 그룹 길이만큼의 행마다 END에서 동기화된다.  따라서:
 *   - ABSORBABLE은 END를 판단 지점으로 표시한다(어디를 비교할지)
 *   - ABSORBABLE_BRANCH 는 A->B->END 내내
 *     state.isAbsorbable=true를 유지시킨다
 *
 * 패턴 예:
 *
 *   패턴: A+ B
 *   요소 0 (A): ABSORBABLE | ABSORBABLE_BRANCH  <- 판단 지점
 *   요소 1 (B): (없음)
 *   -> 매 행마다 A에서 비교한다.  컨텍스트가 B로 이동하면 흡수가
 *      멈춘다.
 *
 *   패턴: (A B)+ C
 *   요소 0 (BEGIN): ABSORBABLE_BRANCH
 *   요소 1 (A): ABSORBABLE_BRANCH
 *   요소 2 (B): ABSORBABLE_BRANCH
 *   요소 3 (END): ABSORBABLE | ABSORBABLE_BRANCH  <- 판단 지점
 *   요소 4 (C): (없음)
 *   -> 2 행마다 END에서 비교한다.  컨텍스트가 C로 이동하면 흡수가
 *      멈춘다.
 *
 *   패턴: (A+ B+)+ C
 *   요소 0 (BEGIN): ABSORBABLE_BRANCH
 *   요소 1 (A): ABSORBABLE | ABSORBABLE_BRANCH  <- 판단 지점
 *   요소 2 (B): (없음)
 *   요소 3 (END): (없음)
 *   요소 4 (C): (없음)
 *   -> 첫 반복 동안 A에서 비교한다.  B+로 옮긴 뒤에는 흡수가 멈춘다.
 *
 * 첫 번째 무제한 구간 전략:
 *   한 경로를 따라, 알고리즘은 요소 0 에서 시작하는 첫 번째 무제한 구간에만
 *   플래그를 붙인다; alternation은 분기별로 훑으므로, 각 분기가 하나씩 기여할
 *   수 있다(A+ | B+는 둘 다 얻는다).  이것으로 충분한 이유는:
 *   - 첫 구간에서의 흡수만으로 이미 O(n) 복잡도를 달성한다
 *   - 이후 구간은 동기화 특성이 다르다
 *   - 중첩된 무제한 패턴은 단순한 흡수로 다루기에는 너무 복잡하다
 *   - 복잡한 패턴(중첩 그룹 등)은 불일치로 인해 자연스럽게 무산된다
 *
 * 런타임 사용법(execRPR.c에서):
 *   - state.isAbsorbable = (previous && elem.ABSORBABLE_BRANCH)
 *   - 단조성: 한 번 false가 되면 계속
 *     false이다(그 영역에 다시 들어올 수 없다)
 *   - context.hasAbsorbableState: 다른 것을 흡수할 수
 *     있다(흡수 가능한 상태가 1 개 이상)
 *   - context.allStatesAbsorbable: 흡수될 수 있다(모든 상태가 흡수 가능)
 *   - 흡수 검사: Ctx1.hasAbsorbable && Ctx2.allAbsorbable 이면, 같은
 *     elemIdx 에서 카운트를 비교하여 Ctx1.count >= Ctx2.count이면 흡수한다
 *
 *-------------------------------------------------------------------------
 */

/*
 * isFixedLengthChildren
 *		elem의 스코프 안 모든 요소가 (중첩된 서브그룹을 포함해) 고정 길이
 *		수량자(min == max)를 가지는지 확인한다.
 *
 * 고정 길이 그룹은 각 자식을 {1,1} 사본으로 풀어놓은 것과 의미상 동등한데,
 * 이는 흡수에 대해 이미 옳다고 증명된 기존 Case 2 이다. 이 검사는 실제로
 * 풀어놓지 않고도 컴파일 타임에 고정 길이 그룹을 알아 낸다.
 *
 * elem에서 시작해 둘러싼 그룹을 닫는 요소까지 next 체인을 따라가며, 지나는
 * 모든 요소에 대해 min == max를 검사한다.  그룹의 수량자는 BEGIN에도
 * END에도 있으므로, 요소당 한 번의 검사로 중첩된 서브그룹도 함께 다루며,
 * 그 서브그룹이 얼마나 깊이 중첩됐는지 알 필요가 없다: tryUnwrapGroup()이
 * 없애지 않은 GROUP{1,1}은 마커를 전혀 내지 않으며, 그 children도
 * 이 영역이 고정 길이가 되려면 마찬가지로 고정 길이여야 한다.  ALT
 * 요소는 거부된다(흡수 가능한 그룹 안의 alternation은 지원하지 않는다).
 *
 * 스코프 안 모든 요소가 고정 길이이면 true를 반환한다.
 */
static bool
isFixedLengthChildren(RPRPattern *pattern, RPRPatternElement *elem)
{
	RPRDepth	scopeDepth = elem->depth;

	/*
	 * isUnboundedStart()에서처럼, depth가 할 수 없는 곳에서 FIN이 순회의
	 * 한계가 된다
	 */
	for (; elem->depth >= scopeDepth && !RPRElemIsFin(elem);
		 elem = &pattern->elements[elem->next])
	{
		/* FIN은 후속 요소가 없는 유일한 요소이며, 그래서 우리를 멈춰 세웠다 */
		Assert(elem->next != RPR_ELEMIDX_INVALID);

		/* 흡수 가능한 그룹 안의 alternation은 지원하지 않는다 */
		if (RPRElemIsAlt(elem))
			return false;

		if (elem->min != elem->max)
			return false;
	}

	return true;
}

/*
 * isUnboundedStart
 *		elem이 무제한 탐욕적 시퀀스를 시작하는지 확인한다.
 *
 * 컨텍스트 흡수가 동작하려면 elem에서 시작하는 시퀀스가 다음을 만족해야 한다:
 *   - 무제한(max = 무한)
 *   - 탐욕적(reluctant가 아님)
 *   - 현재 스코프의 시작 지점
 *
 * 두 가지 경우를 다룬다:
 *   1. 단순 VAR: A+ B C - A가 max=INF이며, 두 플래그를 모두 얻는다
 *   2.  고정 길이 children을 가진 무제한 GROUP: (A B{2})+ C 모든 children이
 *      (중첩된 서브그룹까지 재귀적으로) min == max여야 한다.  이는 {1,1}
 *      VAR들로 풀어놓은 것, 예를 들어 (A B B)+ C와 동등하다.  그룹 안의 모든
 *      요소가 ABSORBABLE_BRANCH 를 얻는다.
 *      무제한 END만 ABSORBABLE(판단 지점)을 얻는다.
 *
 *      아래 예에서 "step"은 그룹을 완전히 한 번 풀어놓았을 때의 VAR
 *      개수이다(반복당 고정 길이).  예:
 *        (A B{2})+ C          - B{2}는 min==max, step=3
 *        (A (B C){2} D)+ E    - 중첩된 {2} 서브그룹, step=6
 *        ((A (B C){2}){2})+   - 이중으로 중첩된 {2}, step=10
 *        (A ((B C{3}){2} D){2} E)+ F  - 깊이 중첩, step=20
 *
 * 흡수가 동작할 수 없는 패턴에는 false를 반환한다:
 *   - A B+ (무제한이 시작 지점이 아님)
 *   - A+? B (무제한 수량자 자체가 reluctant)
 *   - (A | B)+ (그룹 안의 ALT)
 *   - (A B+)+ (그룹 안의 가변 길이 요소)
 *   - (A B{2,5})+ (그룹 안에서 min != max)
 *
 * reluctance 검사는 여기서 살펴보는 수량자만 다룬다.
 * 둘러싼 그룹에 붙은 reluctant 수량자 -- (A+)??에서
 * A+ 자체는 탐욕적인 경우 -- 는 이 함수에 도달하기 전에
 * computeAbsorbabilityRecursive()가 그 그룹의 BEGIN에서 거부한다.
 */
static bool
isUnboundedStart(RPRPattern *pattern, RPRPatternElement *elem)
{
	RPRDepth	startDepth = elem->depth;
	RPRPatternElement *e;

	/* 경우 1: 시작 지점의 단순 무제한 VAR(탐욕적인 경우만) */
	if (RPRElemIsVar(elem) && RPRElemIsUnbounded(elem) &&
		!RPRElemIsReluctant(elem))
	{
		/* 첫 요소에 두 플래그를 모두 설정한다 */
		elem->flags |= RPR_ELEM_ABSORBABLE_BRANCH | RPR_ELEM_ABSORBABLE;
		return true;
	}

	/*
	 * 경우 2: 고정 길이 children을 가진 무제한 GROUP.  각 자식은
	 * (중첩된 서브그룹까지 재귀적으로) min == max여야 하며, 이는 반복당 step
	 * 크기를 고정해서 count-dominance가 성립하게 한다.
	 */
	if (!isFixedLengthChildren(pattern, elem))
		return false;

	/*
	 * startDepth - 1 에서 그룹을 닫는 END를 찾는다.  그룹 마커는
	 * 부모의 depth에 위치하므로, startDepth 보다 얕은 첫 요소가
	 * (startDepth 에 있는 중첩 서브그룹의 것이 아니라) 바로 그 END이다.
	 * depth가 할 수 없는 곳에서 FIN이 순회의 한계가 된다: startDepth ==
	 * 0 이면 더 얕은 것이 없어서 FIN의 next는 배열 밖으로 나가 버린다.
	 */
	e = elem;
	while (e->depth >= startDepth && !RPRElemIsFin(e))
		e = &pattern->elements[e->next];

	/* END는 무제한 탐욕적이어야 한다 */
	if (e->depth == startDepth - 1 &&
		RPRElemIsEnd(e) && RPRElemIsUnbounded(e) &&
		!RPRElemIsReluctant(e))
	{
		RPRPatternElement *endElem = e;

		/* END는 첫 자식을 다시 가리킨다 */
		Assert(&pattern->elements[e->jump] == elem);

		/*
		 * 모든 children에 ABSORBABLE_BRANCH 를, END에만 ABSORBABLE을 설정한다
		 */
		for (e = elem; e != endElem; e = &pattern->elements[e->next])
			e->flags |= RPR_ELEM_ABSORBABLE_BRANCH;
		endElem->flags |= RPR_ELEM_ABSORBABLE_BRANCH | RPR_ELEM_ABSORBABLE;
		return true;
	}

	return false;
}

/*
 * computeAbsorbabilityRecursive
 *		주어진 요소부터 재귀적으로 흡수 가능성을 검사한다.
 *
 * elem이 ALT이면 각 분기를 독립적으로 재귀 검사한다.  각 분기는 자신의 흡수
 * 가능성 상태를 가지며, 어느 한 분기라도 흡수 가능하면 ALT 요소 자체가
 * RPR_ELEM_ABSORBABLE_BRANCH 로 표시된다.
 *
 * BEGIN이면 첫 자식으로 건너뛴다 -- 단, 그룹 자체의 수량자가 탐욕적일 때만.
 * 흡수는 더 이른 컨텍스트가 더 늦은 것을 포섭한다고 가정하는데, reluctant
 * 그룹은 이를 뒤집으므로, isUnboundedStart()는 건네받은 수량자만 보기 때문에
 * (A+)??에서 탐욕적인 A+에는 이 검사가 필요하다.
 *
 * 그 외(VAR)이면 isUnboundedStart 를 통해
 * 그 요소가 무제한 시퀀스를 시작하는지 확인한다.
 */
static void
computeAbsorbabilityRecursive(RPRPattern *pattern,
							  RPRPatternElement *elem,
							  bool *hasAbsorbable)
{
	check_stack_depth();

	if (RPRElemIsAlt(elem))
	{
		/* ALT: SEP 체인을 통해 각 분기를 재귀적으로 검사한다 */
		RPRPatternElement *branch = &pattern->elements[elem->next];
		RPRElemIdx	sepIdx = elem->jump;

		while (sepIdx != RPR_ELEMIDX_INVALID)
		{
			RPRPatternElement *sepElem;
			bool		branchAbsorbable = false;

			/* 이 분기의 내용을 재귀적으로 검사한다 */
			computeAbsorbabilityRecursive(pattern, branch, &branchAbsorbable);
			if (branchAbsorbable)
				*hasAbsorbable = true;

			Assert(sepIdx >= 0 && sepIdx < pattern->numElements);
			sepElem = &pattern->elements[sepIdx];
			Assert(RPRElemIsSep(sepElem));

			/* 마지막 분기의 SEP는 링크가 없어 순회가 끝난다 */
			branch = &pattern->elements[sepElem->next];
			sepIdx = sepElem->jump;
		}

		/* 어느 분기라도 흡수 가능하면 ALT 요소를 표시한다 */
		if (*hasAbsorbable)
			elem->flags |= RPR_ELEM_ABSORBABLE_BRANCH;
	}
	else if (RPRElemIsBegin(elem))
	{
		/*
		 * 흡수 가능 영역이 아니다.  그룹의 수량자는 BEGIN에도 END에도
		 * 있으므로, 이 요소가 그룹을 대표해 답한다.
		 */
		if (RPRElemIsReluctant(elem))
			return;

		/*
		 * BEGIN: 먼저 이 BEGIN의 children을 곧바로 무제한 그룹으로 다뤄
		 * 본다(((A{2} B{3}){2})+ 같은 중첩된 고정 길이 그룹을 처리한다).
		 * 실패하면 첫 자식으로 건너뛰어 이전처럼 재귀한다.
		 */
		if (isUnboundedStart(pattern, &pattern->elements[elem->next]))
		{
			*hasAbsorbable = true;
			elem->flags |= RPR_ELEM_ABSORBABLE_BRANCH;
		}
		else
		{
			computeAbsorbabilityRecursive(pattern,
										  &pattern->elements[elem->next],
										  hasAbsorbable);

			/* 내용이 흡수 가능하면 BEGIN 요소를 표시한다 */
			if (*hasAbsorbable)
				elem->flags |= RPR_ELEM_ABSORBABLE_BRANCH;
		}
	}
	else
	{
		/*
		 * 재귀는 스코프의 첫 요소에서만 시작하며, 결코 END에서 시작하지
		 * 않는다: 위의 BEGIN 경우가 그룹의 본문을 END까지 다룬다.
		 */
		Assert(!RPRElemIsEnd(elem));

		/* ALT도 BEGIN도 아니면: 무제한 시작인지 검사한다 */
		if (isUnboundedStart(pattern, elem))
			*hasAbsorbable = true;
	}
}

/*
 * computeAbsorbability
 *		패턴이 컨텍스트 흡수 최적화를 지원하는지 판단한다.
 *
 * 컨텍스트 흡수는 더 오래된 컨텍스트보다 긴 매치를 만들어 낼 수 없는 더 최근
 * 컨텍스트를 흡수하여 불필요한 매치 탐색을 없앤다.  이는 O(n^2) -> O(n) 성능
 * 향상을 달성한다.
 *
 * 패턴 시작 지점의 탐욕적 무제한 수량자만 흡수 가능할 수 있다.  reluctant
 * 수량자는 -- 무제한 수량자 자체이든 그것을 둘러싼 그룹 수량자이든 -- 안전한
 * 흡수에 필요한 단조 감소 속성을 유지하지 않으므로 제외한다.
 *
 * 이 함수는 두 플래그를 설정한다:
 *   RPR_ELEM_ABSORBABLE: 흡수 판단 지점
 *     - 단순 무제한 VAR: VAR 자신(예: A+에서 A)
 *     - 무제한 GROUP: END 요소(예: (A B)+에서 END)
 *   RPR_ELEM_ABSORBABLE_BRANCH: 흡수 가능 영역 안의 모든 요소
 *     - 단순 무제한 VAR: VAR 자신
 *     - 무제한 GROUP: (중첩된 서브그룹을 포함한) 본문 전체와 그룹의 END
 *     - 어느 경우든, 거기까지 가는 경로에 있는 둘러싼 BEGIN/ALT도 포함
 *
 * 예:
 *   A+ B C         - 흡수 가능(A가 두 플래그를 모두 얻는다)
 *   (A B)+ C       - 흡수 가능(BEGIN,A,B,END가 BRANCH를, END가
 *                    ABSORBABLE을 얻는다)
 *   A B+           - 흡수 불가(무제한이 시작 지점이 아님)
 *   A+? B C        - 흡수 불가(reluctant 수량자)
 *   (A+ B+)+       - 첫 반복의 첫 A+만(중첩된 무제한은 지원하지 않음)
 *   A+ | B+        - 두 분기 모두 독립적으로 흡수 가능
 *   A+ | C D       - A+ 분기만 흡수 가능(C D 분기는 흡수 불가)
 *   ((A+ B) | C) D - 중첩된 ALT: A+ 분기가 흡수 가능
 */
static void
computeAbsorbability(RPRPattern *pattern)
{
	bool		hasAbsorbable = false;

	/* 파서는 항상 요소를 적어도 하나 + FIN을 만들어 낸다 */
	Assert(pattern->numElements >= 2);

	/* 첫 요소부터 재귀를 시작한다 */
	computeAbsorbabilityRecursive(pattern, pattern->elements, &hasAbsorbable);
	pattern->isAbsorbable = hasAbsorbable;
}

/*
 * buildRPRPattern
 *		패턴 파스 트리를 평탄화된 바이트코드 배열로 컴파일한다.
 *
 * 컴파일 단계:
 *   1. 파스 트리 최적화(평탄화, 병합, 중복 제거)
 *   2. 스캔: 변수를 모으고 요소 수를 센다(패스 1)
 *   3. 결과 구조체 할당
 *   4. 파스 트리로부터 요소를 채운다(패스 2)
 *   5. 패턴 구조체 마무리
 *   6. 컨텍스트 흡수 가능 여부 계산
 *
 * 플랜 생성 중 createplan.c에서 호출된다.
 */
RPRPattern *
buildRPRPattern(RPRPatternNode *pattern, List *defineClause,
				RPSkipTo rpSkipTo, int frameOptions,
				bool hasMatchStartDependent)
{
	RPRPattern *result;
	RPRPatternNode *optimized;
	char	   *varNamesStack[RPR_VARID_MAX + 1];
	int			numVars;
	int			numElements;
	RPRDepth	maxDepth;
	int			idx;

	/* 호출자는 호출 전에 NULL 패턴인지 확인해야 한다 */
	Assert(pattern != NULL);
	/* RPR은 ROWS 전용이다: transformRPR()이 RANGE/GROUPS를 미리 거부한다 */
	Assert(frameOptions & FRAMEOPTION_ROWS);

	/* 패턴 트리를 최적화한다 */
	optimized = optimizeRPRPattern(copyObject(pattern));

	numVars = 0;

	/*
	 * DEFINE 순서대로 DEFINE 변수 이름으로 varNamesStack 을 채운다.  이렇게
	 * 하면 varId == defineClause 인덱스가 되어, 런타임 매핑이 필요 없다.
	 */
	foreach_node(TargetEntry, te, defineClause)
	{
		/* 파서는 각 DEFINE 항목에 항상 이름을 붙인다 */
		Assert(te->resname != NULL);

		varNamesStack[numVars++] = te->resname;
	}

	/* 패턴을 스캔한다: 변수를 모으고, 요소 수를 세고, 한계를 검증한다 */
	scanRPRPattern(optimized, varNamesStack, &numVars, &numElements, &maxDepth);

	/*
	 * numVars 는 RPR_VARID_MAX + 1 에 이를 수 있다(유효한 varIds 는
	 * 0..RPR_VARID_MAX 이다)
	 */
	Assert(numVars <= RPR_VARID_MAX + 1);

	/* 결과 구조체를 할당한다 */
	result = makeRPRPattern(numVars, numElements, maxDepth, varNamesStack);

	/* 요소를 채운다(패스 2) */
	idx = 0;
	fillRPRPattern(optimized, result, &idx, 0);

	/* 마무리: next 포인터, 플래그를 설정하고 FIN 마커를 추가한다 */
	finalizeRPRPattern(result);

	/*
	 * 컨텍스트 흡수 가능 여부를 계산한다.  흡수는 구조적 흡수 가능성과 런타임
	 * 조건을 모두 필요로 한다.  불필요한 패턴 분석을 피하려고 런타임 조건을
	 * 먼저 검사한다.
	 *
	 * 흡수를 위한 런타임 조건:
	 *
	 * 1. (SKIP TO NEXT ROW가 아니라) SKIP TO PAST LAST ROW가 필요하다:
	 * NEXT ROW에서는 매치가 겹치고 모든 행이 자신의 매치를 보고해야 하므로,
	 * 흡수(결과 하나를 공유하는 것)는 의미상 가능하지 않다.  완료된
	 * 컨텍스트는 자신의 시작 행이 조회될 때까지 남아 있는데, 이는 행 단위
	 * 매치 보고에 내재한 비용이지 흡수로 없앨 수 있는 중복이 아니다.
	 *
	 * 2. (한계가 있는 ROWS가 아니라) 무제한 프레임 끝이 필요하다.
	 * 프레임에 한계가 있으면(예: ROWS BETWEEN CURRENT ROW AND 10 FOLLOWING),
	 * 매치가 프레임 경계에서 잘릴 수 있다.  이는 흡수 의미론을 바꾼다 -
	 * 프레임 한계가 각 컨텍스트에 다르게 적용될 때는 더 오래된 컨텍스트가
	 * 반드시 더 긴 매치를 만들어 내지는 않는다.
	 *
	 * 3. 어떤 DEFINE도 match_start 에 의존해서는 안 된다: 그런 변수는
	 * 자신의 매치 시작을 기준으로 평가되므로, 시작 위치만 다른 두 컨텍스트가
	 * 같은 행을 다르게 분류할 수 있고, 더 오래된 쪽이 더 이상 더 최근 것을
	 * 포괄하지 못하게 된다.
	 */
	if (rpSkipTo == ST_PAST_LAST_ROW &&
		(frameOptions & FRAMEOPTION_END_UNBOUNDED_FOLLOWING) &&
		!hasMatchStartDependent)
	{
		/* 런타임 조건 충족 - 구조적 흡수 가능성을 검사한다 */
		computeAbsorbability(result);
	}

	return result;
}
