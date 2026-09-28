-- ============================================================
-- RPR NFA 테스트
-- 행 패턴 인식(RPR) NFA 런타임 실행 테스트
-- ============================================================
--
-- 이 테스트 스위트는 execRPR.c 에 있는 NFA(비결정적 유한 오토마타,
-- Non-deterministic Finite Automaton) 런타임 실행 엔진을 검증한다. 이 엔진은
-- nodeWindowAgg.c 의 update_reduced_frame()에 의해 구동된다.
--
-- 테스트 전략:
--   각 행에서 어떤 패턴 변수가 일치하는지를 ARRAY 플래그로 직접 지정하는
--   대각선(diagonal) 패턴 방식을 사용한다.
--
-- 테스트 범위:
--   기본 NFA 흐름 (match->absorb->advance)
--   흡수 최적화
--   컨텍스트 생명주기 관리
--   Advance 단계 (엡실론 전이)
--   Match 단계 (변수 매칭)
--   프레임 경계 처리
--   상태 관리 (중복 제거)
--   통계 및 진단
--   수량자 런타임 동작
--   병적(pathological) 패턴 보호
--   교대 런타임 동작
--   깊이 중첩된 그룹
--   SKIP 옵션 (런타임)
--   INITIAL 모드 (런타임)
--   프레임 경계 변형
--   특수 파티션 사례
--   DEFINE 특수 사례
--   흡수 동적 플래그
--   영-소모 사이클 감지
--   표준 절 7: 형식적 패턴 매칭 규칙
--
-- 책임 범위:
--   - NFA 런타임 실행 경로
--   - 컨텍스트/상태 생명주기 관리
--   - 런타임 경계 조건 및 보호
--
-- 여기서 테스트하지 않음 (다른 파일에서 다룸):
--   - 패턴 구문분석/최적화 (rpr_base.sql)
--   - EXPLAIN 출력 (rpr_explain.sql)
--   - PREV/NEXT 의미론 (rpr.sql)
-- ============================================================

-- ============================================================
-- 기본 NFA 흐름
-- ============================================================

-- 단순 순차 패턴
WITH test_sequential AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['D']),
        (5, ARRAY['_'])  -- 매치 없음
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_sequential
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 수량자가 있는 패턴 (A+ B+ C+)
WITH test_quantified AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['B']),
        (6, ARRAY['C']),
        (7, ARRAY['C']),
        (8, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quantified
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B+ C+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 선택적 패턴 (A B? C)
WITH test_optional AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['C']),  -- B 건너뜀
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['C']),  -- B 매치됨
        (6, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_optional
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B? C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 교대 패턴 (A (B|C) D)
WITH test_alternation AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),  -- 첫 번째 분기
        (3, ARRAY['D']),
        (4, ARRAY['A']),
        (5, ARRAY['C']),  -- 두 번째 분기
        (6, ARRAY['D']),
        (7, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alternation
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A (B | C) D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- ============================================================
-- 흡수 최적화
-- ============================================================

-- 이 절의 모든 테스트는 SKIP PAST LAST ROW 와 무제한 프레임을 사용한다.
-- buildRPRPattern()이 흡수를 활성화하는 유일한 설정이 이것이므로, 흡수 가능한
-- 형태는 실제로 흡수되고 흡수 불가능한 형태는 SKIP 모드가 아니라 그 구조
-- 때문에 배제된다.

-- 흡수 가능한 패턴 (A+)
-- 2-4 행에서 시작된 컨텍스트들은 1 행의
-- 컨텍스트에 흡수되어, 하나의 매치 1-4 가 된다.
WITH test_absorbable AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_absorbable
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 흡수 가능/불가능이 섞인 패턴 ((A+) | B)
-- A+ 분기만 흡수 가능하다: 2-3 행은 1-3 매치에 흡수되고, 4 행의 컨텍스트는 B
-- 분기를 통해 여전히 매치된다.
WITH test_mixed_absorption AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_mixed_absorption
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+) | B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 상태 커버리지 (같은 elemIdx, 다른 count)
-- A{2,}는 흡수 가능하다: 2 행의 A 상태(count 1)는 최소값 미만임에도 1 행의
-- 상태(count 2)에 의해 커버되며, 3 행도 마찬가지다.
WITH test_state_coverage AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_state_coverage
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{2,} B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 소극적 패턴 (A+?) - 흡수 불가능
-- 위의 탐욕적 A+와 비교하라: 설정은 흡수를 허용하지만 소극적
-- 수량자는 결코 흡수 가능하지 않으며, 각 컨텍스트는 자신의 1 행
-- 최소값에서 멈추므로 1-4 행 각각이 자기만의 매치를 시작한다.
WITH test_reluctant_absorption AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_absorption
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+?)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 고정 접미사가 있는 흡수: A+ B
-- 1 행이 아직 A+ 안에 있는 동안 2-3 행이 흡수된다; 이어서 B 가 1-4 매치를
-- 끝내고, 그 안에서 시작한 4 행의 컨텍스트는 건너뛴다.
WITH test_absorb_suffix AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_suffix
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ALT 에서의 분기별 흡수: B+ C | B+ D
-- 두 분기에서 1 행의 B+ 상태가 2-3 행의 상태를 커버하여 흡수되고, D 분기가 1-4
-- 매치를 끝낸다.
WITH test_absorb_alt AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['B']),
        (4, ARRAY['D']),
        (5, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_alt
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (B+ C | B+ D)
    DEFINE
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 흡수 불가능: A B+ (무제한 요소가 첫 위치가 아님)
-- 설정이 허용하더라도 아무것도 흡수되지 않는다; 2-4 행의 컨텍스트는 대신 1-4
-- 매치가 그 위로 자라면서 건너뛰어진다.
WITH test_no_absorb AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['B']),
        (4, ARRAY['B']),
        (5, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_no_absorb
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- GROUP 병합이 흡수를 가능하게 한다: (A B) (A B)+는 (A B){2,}로 최적화된다
-- 3 행과 5 행의 컨텍스트는 1 행보다 한 반복 뒤처져서 그룹 END 에 도달하고
-- 거기서 흡수된다; 매치는 1-6 이다.
WITH test_absorb_group AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B']),
        (7, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_group
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B) (A B)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 연속된 두 개의 무제한 그룹: (A B)+ (C D)+
-- 앞의 그룹 (A B)+는 흡수 가능하다 (무제한, 다중 요소); (C D)+는
-- 이와 병합되지 않는 별개의 형제 그룹이다.  앞 그룹이 형제
-- 그룹으로 빠져나갈 때, 본체의 leaf-VAR count 는 형제 그룹이
-- 공유하는 depth 슬롯으로 새어 들어가지 않도록 지워져야 한다.
WITH test_absorb_two_groups AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['D']),
        (5, ARRAY['A']),
        (6, ARRAY['B']),
        (7, ARRAY['C']),
        (8, ARRAY['D'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_two_groups
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B)+ (C D)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 고정 길이 그룹 흡수: (A B{2})+ C
-- B{2}는 min == max 이며, (A B B)+ C 로 풀어 쓴 것과 동등하다
WITH test_absorb_fixedlen AS (
    SELECT * FROM (VALUES
        (1,  ARRAY['A']),
        (2,  ARRAY['B']),
        (3,  ARRAY['B']),
        (4,  ARRAY['A']),
        (5,  ARRAY['B']),
        (6,  ARRAY['B']),
        (7,  ARRAY['A']),
        (8,  ARRAY['B']),
        (9,  ARRAY['B']),
        (10, ARRAY['C']),
        (11, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_fixedlen
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B{2})+ C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 연속된 변수가 고정 길이로 병합됨: (A B B)+ -> (A B{2})+
WITH test_absorb_consecutive AS (
    SELECT * FROM (VALUES
        (1,  ARRAY['A']),
        (2,  ARRAY['B']),
        (3,  ARRAY['B']),
        (4,  ARRAY['A']),
        (5,  ARRAY['B']),
        (6,  ARRAY['B']),
        (7,  ARRAY['A']),
        (8,  ARRAY['B']),
        (9,  ARRAY['B']),
        (10, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_consecutive
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B B)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 중첩된 고정 길이 그룹 흡수: (A (B C){2} D)+ E 내부 그룹
-- {2}는 min == max 이다; 재귀적 검사를 통해 흡수 가능하다
-- step_size = 1 + (1+1)*2 + 1 = 6
WITH test_absorb_nested_fixedlen AS (
    SELECT * FROM (VALUES
        (1,  ARRAY['A']),
        (2,  ARRAY['B']),
        (3,  ARRAY['C']),
        (4,  ARRAY['B']),
        (5,  ARRAY['C']),
        (6,  ARRAY['D']),
        (7,  ARRAY['A']),
        (8,  ARRAY['B']),
        (9,  ARRAY['C']),
        (10, ARRAY['B']),
        (11, ARRAY['C']),
        (12, ARRAY['D']),
        (13, ARRAY['E']),
        (14, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_nested_fixedlen
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A (B C){2} D)+ E)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags)
);

-- 이중으로 중첩된 고정 길이 그룹 흡수: (A ((B C{3}){2} D){2} E)+ F step_size =
-- 1 + ((1+3)*2+1)*2 + 1 = 20; 2 회 반복 + F = 41 행
WITH test_absorb_doubly_nested AS (
    SELECT v AS id, ARRAY[
        CASE
            WHEN v % 41 IN (1, 21)  THEN 'A'
            WHEN v % 41 IN (2, 6, 11, 15, 22, 26, 31, 35) THEN 'B'
            WHEN v % 41 IN (3,4,5, 7,8,9, 12,13,14, 16,17,18,
                            23,24,25, 27,28,29, 32,33,34, 36,37,38) THEN 'C'
            WHEN v % 41 IN (10, 19, 30, 39) THEN 'D'
            WHEN v % 41 IN (20, 40) THEN 'E'
            WHEN v % 41 = 0 THEN 'F'
            ELSE 'X'
        END
    ] AS flags
    FROM generate_series(1, 82) AS s(v)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_doubly_nested
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A ((B C C C){2} D){2} E)+ F)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags),
        F AS 'F' = ANY(flags)
);

-- 3 단계 END 연쇄: ((A (B C){2}){2})+
-- END(BC{2}) -> END(A..{2}) -> END(+)로 이어지는 연쇄를 테스트한다 +의 2 회
-- 반복, 각 10 행: (A B C B C)(A B C B C)
WITH test_absorb_3level_end AS (
    SELECT * FROM (VALUES
        (1,  ARRAY['A']),  -- 1 번째 + 반복, 1 번째 {2}, A
        (2,  ARRAY['B']),
        (3,  ARRAY['C']),
        (4,  ARRAY['B']),
        (5,  ARRAY['C']),  -- 1 번째 (BC){2} 완료
        (6,  ARRAY['A']),  -- 1 번째 + 반복, 2 번째 {2}, A
        (7,  ARRAY['B']),
        (8,  ARRAY['C']),
        (9,  ARRAY['B']),
        (10, ARRAY['C']),  -- 2번째 (BC){2} 완료, 1번째 {2} 완료, 1번째 + 반복
                            -- 완료
        (11, ARRAY['A']),  -- 2 번째 + 반복, 1 번째 {2}, A
        (12, ARRAY['B']),
        (13, ARRAY['C']),
        (14, ARRAY['B']),
        (15, ARRAY['C']),
        (16, ARRAY['A']),  -- 2 번째 + 반복, 2 번째 {2}, A
        (17, ARRAY['B']),
        (18, ARRAY['C']),
        (19, ARRAY['B']),
        (20, ARRAY['C']),  -- 2 번째 (BC){2} 완료
        (21, ARRAY['X'])   -- 매치 없음, + 종료
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_absorb_3level_end
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A (B C){2}){2})+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 여러 개의 무제한 요소: A+ B+ (첫 요소가 무제한이면 흡수가 가능해진다)
-- 1 행이 A+에 있는 동안 2 행이 흡수된다; B+에 들어가면 아무것도 흡수 가능하지
-- 않으며, 3-4 행은 대신 1-4 매치에 의해 건너뛰어진다.
WITH test_multi_unbounded AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['B']),
        (5, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_multi_unbounded
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- 컨텍스트 생명주기
-- ============================================================

-- 여러 개의 중첩된 컨텍스트 (SKIP TO NEXT ROW)
WITH test_overlapping_contexts AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_overlapping_contexts
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 실패한 컨텍스트 정리 (조기 실패)
WITH test_context_cleanup AS (
    SELECT * FROM (VALUES
        (1, ARRAY['_']),  -- 첫 행에서 가지치기됨
        (2, ARRAY['A']),
        (3, ARRAY['_']),  -- 2 행 이후 불일치
        (4, ARRAY['A']),
        (5, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_context_cleanup
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 파티션 끝 (미완료 컨텍스트)
WITH test_partition_end AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A'])
        -- 패턴은 B 를 요구하지만 파티션이 끝난다
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_partition_end
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 처리 중에 만나는 완료된 컨텍스트
-- 패턴 (A | B C D): Ctx1 은 긴 B->C->D 경로를 취하고, Ctx2 는 짧은 A 경로를
-- 취해 먼저 완료된다.  다음 행은 states=NULL 인 Ctx2 를 만나 이를 건너뛴다.
WITH test_completed_ctx AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B', '_']),
        (2, ARRAY['C', 'A']),
        (3, ARRAY['D', '_']),
        (4, ARRAY['_', '_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_completed_ctx
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A | B C D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 소극적 컨텍스트 생명주기 (SKIP TO NEXT ROW 를 사용하는 A+? B) A+?는
-- 일찍 빠져나가지만 B 가 없으면 루프로 되돌아간다.  SKIP TO NEXT ROW 는
-- 흡수를 비활성화하므로 (또한 A+?는 어차피 흡수 가능하지 않다),
-- 1 행과 2 행의 중첩된 컨텍스트가 둘 다 살아남는다.
WITH test_reluctant_context AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_context
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- Advance 단계 (엡실론 전이)
-- ============================================================

-- 중첩된 그룹 ((A B)+)
WITH test_nested_groups AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B']),
        (7, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_groups
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A B)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 여러 교대 분기 (A (B|C|D) E)
WITH test_multi_alt AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['E']),
        (4, ARRAY['A']),
        (5, ARRAY['C']),
        (6, ARRAY['E']),
        (7, ARRAY['A']),
        (8, ARRAY['D']),
        (9, ARRAY['E'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_multi_alt
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A (B | C | D) E)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags)
);

-- 시작 부분의 선택적 VAR (A? B C)
WITH test_optional_var AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),  -- A 건너뜀
        (2, ARRAY['C']),
        (3, ARRAY['A']),  -- A 매치됨
        (4, ARRAY['B']),
        (5, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_optional_var
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A? B C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 중첩된 교대 ((A|B) (C|D))
WITH test_nested_alt AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['C']),  -- A C
        (3, ARRAY['A']),
        (4, ARRAY['D']),  -- A D
        (5, ARRAY['B']),
        (6, ARRAY['C']),  -- B C
        (7, ARRAY['B']),
        (8, ARRAY['D'])   -- B D
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_alt
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A | B) (C | D))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 탐욕적/소극적이 섞인 시퀀스: A+?  B+ (A 는 소극적, B 는 탐욕적) A 는 가능한
-- 한 일찍 빠져나가고, B 는 나머지를 탐욕적으로 소비한다
WITH test_mixed_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A','B']),
        (4, ARRAY['B']),
        (5, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_mixed_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+? B+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 선택적 소극적 그룹: (A B)?? C
-- 소극적 그룹 진입은 skip 을 먼저 시도하지만, skip 경로는 1 행에 C 를
-- 요구하는데 1 행은 A 이므로 skip 은 실패한다.  entry 경로는 성공한다: A(1)
-- B(2) C(3).
WITH test_optional_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_optional_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B)?? C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 선두가 아닌 소극적 선택적 VAR: (B A?? C)
-- 소극적 A??는 skip 을 선호해야 하며, A 를 매치되지 않은 채로
-- 두고 B(1) C(2)에 매치해야 한다 (match_end 2).  위의 선두/그룹
-- 소극적 사례들은 begin 경로를 거치지만, 이 테스트는 선두가 아닌
-- skip 경로를 검사하며, 이 경로도 소극적 순서를 지켜야 한다.
WITH test_nonleading_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A', 'C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nonleading_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (B A?? C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- nullable 하고 소극적인 본체에 대한 소극적 외부 수량자: SQL/RPR 의미론은
-- 최단(빈) 매치를 요구한다.  count<min 인 경우 엔진은 본체가 빈 매치를 선호할
-- 때 fast-forward(이탈) 경로를 선호해야 하고, 이탈이 FIN 에 도달하면 더 긴
-- 매치를 억제해야 한다.  이는 형제 관계인 min<=count<max 분기를 그대로
-- 반영한다.  2 단계의 탐욕적/소극적 행렬에, min>=2 경계와 단일 수량자 대조군을
-- 더해 동작을 국소화한다: 행 소비 여부는 내부 수량자가 결정하므로, 본체가
-- 소극적인 모든 열은 0 에 머무르고, 본체가 탐욕적인 두 열은 외부 수량자에 따라
-- 갈린다 -- gg 는 가장 긴 매치를 취하고, rg 는 1 행을 취한다.
WITH t(id, isa) AS (VALUES (1, true), (2, true), (3, true), (4, false))
SELECT id,
       count(*) OVER gg  AS gg,     -- (A?)+      탐욕적 / 탐욕적
       count(*) OVER gr  AS gr,     -- (A??)+     탐욕적 / 소극적
       count(*) OVER rg  AS rg,     -- (A?)+?     소극적 / 탐욕적
       count(*) OVER rr  AS rr,     -- (A??)+?    소극적 / 소극적
       count(*) OVER rr2 AS rr2,    -- (A??){2,}? 소극적, min>=2 경계
       count(*) OVER ca  AS ca,     -- A??        단일 소극적 대조군
       count(*) OVER cs  AS cs      -- A*?        단일 소극적 대조군
FROM t
WINDOW gg  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A?)+)      DEFINE A AS isa),
       gr  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A??)+)     DEFINE A AS isa),
       rg  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A?)+?)     DEFINE A AS isa),
       rr  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A??)+?)    DEFINE A AS isa),
       rr2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A??){2,}?) DEFINE A AS isa),
       ca  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A??)        DEFINE A AS isa),
       cs  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*?)        DEFINE A AS isa);

-- 다중 요소 본체에 대한 같은 탐욕적/소극적 대조.  위의 열들은 모두
-- 단일 변수 본체를 가지므로, 그룹의 END 에 도달하는 빈-선호 비트는
-- 항상 하나의 자식에서 왔다; 여기서는 이 비트가 fillRPRPattern()이
-- 시퀀스의 자식들에 대해 수행하는 AND-축소를 견뎌내야 한다.
-- 탐욕적 본체는 가장 긴 매치를 취하고, 소극적 본체는 빈 유도를
-- 선호하며, min>=2 쌍은 외부 경계가 이를 바꾸지 않음을 보여준다.
WITH t(id, isa, isb) AS
  (VALUES (1,true,false),(2,false,true),(3,true,false),(4,false,true),(5,false,false))
SELECT id,
       count(*) OVER gg  AS gg,     -- (A? B?)+      탐욕적 본체
       count(*) OVER gr  AS gr,     -- (A?? B??)+    소극적 본체
       count(*) OVER gg2 AS gg2,    -- (A? B?){2,}   탐욕적 본체, min>=2
       count(*) OVER gr2 AS gr2     -- (A?? B??){2,} 소극적 본체, min>=2
FROM t
WINDOW gg  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A? B?)+)      DEFINE A AS isa, B AS isb),
       gr  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A?? B??)+)    DEFINE A AS isa, B AS isb),
       gg2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A? B?){2,})   DEFINE A AS isa, B AS isb),
       gr2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A?? B??){2,}) DEFINE A AS isa, B AS isb);

-- 수량자가 붙은 교대 안에서의 분기 위치.  fillRPRPatternAlt()는 모든 분기에
-- 걸쳐 nullability 를 OR 로 묶지만, 빈-선호는 오직 첫 번째 분기에서만
-- 가져오므로 두 축소는 비대칭적이다. 이 파일의 다른 곳에 있는 모든 빈-선호
-- 분기는 자신의 교대를 이끄는데, 이는 비트를 전파하는 방향만을 검사한다; 이
-- 열들은 비트를 억제해야 하는 방향을 검사한다.  빈-선호 분기가 두 번째에 오면
-- 그룹은 nullable 하지만 빈-선호는 아니므로 loop-back 이 먼저 탐색되어 매치가
-- 길게 진행된다; 분기 순서를 바꾸면 빈 유도가 이긴다. 이 둘을 구별할 수 있는
-- 것은 min>=2 형태뿐이다 -- min 1 에서는 이탈이 어느 쪽으로도 도달 가능하다.
WITH t(id, isa, isb) AS
  (VALUES (1,true,false),(2,true,false),(3,true,false),(4,false,false))
SELECT id,
       count(*) OVER nf1 AS nf1,    -- (A | B??){2,}  빈-선호 분기가 두 번째
       count(*) OVER nf2 AS nf2,    -- (A | B*?){2,}  마찬가지, star 를 사용
       count(*) OVER fst AS fst,    -- (B?? | A){2,}  빈-선호 분기가 첫 번째
       count(*) OVER nfp AS nfp     -- (A | B??)+     min 1 에서 nf1 과 동일
FROM t
WINDOW nf1 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A | B??){2,}) DEFINE A AS isa, B AS isb),
       nf2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A | B*?){2,}) DEFINE A AS isa, B AS isb),
       fst AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((B?? | A){2,}) DEFINE A AS isa, B AS isb),
       nfp AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A | B??)+)    DEFINE A AS isa, B AS isb);

-- 이중으로 중첩된 소극적 nullable 그룹: (((A??){2,}?){2,}?).  소극적
-- 수량자는 옵티마이저의 평탄화를 비활성화하므로 두 단계가 모두 살아남고,
-- 내부 그룹의 END->next 는 외부 END 에 떨어진다.  이는 EMPTY_LOOP
-- fast-forward(count < min)에서의 END->END count 증가를 검사한다.
WITH t(id, isa) AS (VALUES (1, true), (2, true), (3, false))
SELECT id, count(*) OVER w AS c
FROM t
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (((A??){2,}?){2,}?)
    DEFINE A AS isa
);

-- 뒤따르는 요소가 있는, 선두가 아닌 소극적 선택적 GROUP: (B (A X)?? C)
-- 위의 VAR 사례와 비슷하지만 다중 요소 그룹이다; 이미 소극적 순서를
-- 지키는 begin 경로를 거친다.  소극적 (A X)??는 skip 해야 하며, 그룹은
-- (FIN 이 아니라) 뒤따르는 C 로 건너뛰어져서 B(1) C(2)에 매치한다.
WITH test_nonleading_reluctant_group AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A', 'C']),
        (3, ARRAY['X']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nonleading_reluctant_group
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (B (A X)?? C)
    DEFINE
        A AS 'A' = ANY(flags),
        X AS 'X' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 필수 뒤 요소가 있는 소극적 nullable 그룹: ((A??){2,}? B).
-- min=2 는 소극적 fast-forward 가 loop-back 하도록 강제한다
-- (B 가 매치될 때까지 FIN 으로 빠져나갈 수 없다); 이는 nfa_advance_end
-- 안의 두 번째 loop-back route_to_elem 호출 지점을 검사한다.
-- B 는 그룹의 exit 행에서 실패하므로 첫 번째 매치만 살아남는다.
WITH test_reluctant_nullable_follower AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_nullable_follower
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A??){2,}? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 탐욕적/소극적 시퀀스: A+ B+?  (A 는 탐욕적, 끝의 B 는 소극적) A 는
-- 탐욕적으로 소비하고, B+?는 최소 매치 이후 FIN 으로 빠져나간다
WITH test_greedy_then_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_greedy_then_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B+?)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 소극적 선택적 그룹의 skip-to-FIN
-- 소극적 선택적 그룹의 skip 경로가 FIN 에 도달하면, 그룹의 entry 경로는
-- 버려진다.  패턴: C (A B)??  -- C 가 매치된 후, 소극적 그룹 (A B)??는 skip 을
-- 선호한다.  skip 은 FIN 으로 이어지므로 (그룹이 마지막 요소이므로), 매치는 C
-- 만으로 완료된다.
WITH test_begin_skip_fin AS (
    SELECT * FROM (VALUES
        (1, ARRAY['C']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['C','A']),
        (5, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_begin_skip_fin
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (C (A B)??)
    DEFINE
        C AS 'C' = ANY(flags),
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- Match 단계
-- ============================================================

-- END 가 뒤따르는 단순 VAR (A B C 모두 min=max=1)
WITH test_simple_var AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_simple_var
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- VAR max 초과 (A{2,3})
WITH test_max_exceeded AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),  -- Max = 3
        (4, ARRAY['A']),  -- max 초과, 상태 제거됨
        (5, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_max_exceeded
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A{2,3} B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 매치되지 않는 VAR (DEFINE false)
WITH test_non_matching AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['_']),  -- B 매치되지 않음 (DEFINE false)
        (3, ARRAY['A']),
        (4, ARRAY['B']),  -- B 매치됨
        (5, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_non_matching
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ============================================================
-- 프레임 경계 처리
-- ============================================================

-- 제한된 프레임 (ROWS BETWEEN CURRENT ROW AND 3 FOLLOWING)
WITH test_limited_frame AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),  -- 3 FOLLOWING 이내
        (5, ARRAY['B']),  -- 1 행 기준 3 FOLLOWING 을 벗어남
        (6, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_limited_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 3 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 무제한 프레임 (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
WITH test_unbounded_frame AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['B'])  -- 시작에서 멀지만 무제한이다
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_unbounded_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 매치가 프레임 경계를 초과함
WITH test_frame_exceeded AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A'])
        -- 프레임은 3 행에서 끝나고 (2 FOLLOWING), B 는 나타나지 않는다
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_frame_exceeded
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 프레임 경계에 의해 강제된 불일치
-- 처리 도중에 컨텍스트의 프레임 경계가
-- 초과되도록 충분한 행을 가진 제한된 프레임.
WITH test_frame_boundary AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_frame_boundary
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 제한된 프레임에서의 소극적 매칭 (2 FOLLOWING 을 가진 A+? B) 소극적 매칭은
-- 일찍 빠져나가고, B 는 프레임 경계 안에 있어야 한다
WITH test_reluctant_frame AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- 상태 관리
-- ============================================================

-- 중복 상태 생성
WITH test_duplicate_states AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A', 'B']),  -- A와 B가 모두 매치됨
                               -- (서로 다른 경로로 중복 상태를 만든다)
        (2, ARRAY['C', '_']),
        (3, ARRAY['D', '_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_duplicate_states
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A | B) C D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 소극적 중복 상태 처리
-- (A+? | B+?)는 이탈 상태와 loop 상태를 만든다; 이탈 경로가 수렴할 수 있다
WITH test_reluctant_dedup AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['A','B']),
        (3, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_dedup
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A+? | B+?))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 큰 패턴 (free list 에 부하를 준다)
WITH test_large_pattern AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['D']),
        (5, ARRAY['E']),
        (6, ARRAY['F']),
        (7, ARRAY['G']),
        (8, ARRAY['H']),
        (9, ARRAY['I']),
        (10, ARRAY['J'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_large_pattern
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C D E F G H I J)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags),
        F AS 'F' = ANY(flags),
        G AS 'G' = ANY(flags),
        H AS 'H' = ANY(flags),
        I AS 'I' = ANY(flags),
        J AS 'J' = ANY(flags)
);

-- 긴 파티션 (1024 행 초과), 한 행씩 걸러 매치
WITH test_map_realloc AS (
    SELECT id, CASE WHEN id % 2 = 1 THEN ARRAY['A'] ELSE ARRAY['B'] END AS flags
    FROM generate_series(1, 1100) AS id
)
SELECT count(*), min(match_start), max(match_end)
FROM (
    SELECT id, flags,
           first_value(id) OVER w AS match_start,
           last_value(id) OVER w AS match_end
    FROM test_map_realloc
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP TO NEXT ROW
        PATTERN (A B)
        DEFINE
            A AS 'A' = ANY(flags),
            B AS 'B' = ANY(flags)
    )
) sub;

-- ============================================================
-- 통계 및 진단
-- ============================================================

-- EXPLAIN ANALYZE로 쿼리를 실행하고 플랫폼에 무관한 Pattern 줄과 NFA 카운터만
-- 남긴다; 계획의 나머지 부분(정렬 및 저장 메모리)은 플랫폼에 무관하지 않다.
-- 계획 출력은 rpr_explain 에서 다룬다.
CREATE FUNCTION rpr_nfa_counters(query text) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
    ln text;
BEGIN
    FOR ln IN EXECUTE
        'EXPLAIN (ANALYZE, BUFFERS OFF, COSTS OFF, TIMING OFF, SUMMARY OFF) '
        || query
    LOOP
        IF ln ~ '^\s*(Pattern|NFA)' THEN
            RETURN NEXT ltrim(ln);
        END IF;
    END LOOP;
END;
$$;

-- 매치된 컨텍스트
WITH test_matched AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_matched
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 가지치기된 컨텍스트 (첫 행에서 실패)
WITH test_pruned AS (
    SELECT * FROM (VALUES
        (1, ARRAY['_']),  -- 가지치기됨
        (2, ARRAY['_']),  -- 가지치기됨
        (3, ARRAY['A']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_pruned
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 불일치한 컨텍스트 (여러 행 이후 실패)
WITH test_mismatched AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['_']),  -- 2 행 이후 불일치
        (4, ARRAY['A']),
        (5, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_mismatched
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 소극적 A+?는 결코 흡수 가능하지 않다.  행과 패턴은
-- test_reluctant_absorption 의 것과 같으며, 그 결과는
-- 네 개의 1 행 매치를 보여준다; 여기서 Pattern 줄에는 흡수
-- 표시가 없고 흡수되거나 건너뛰어지는 컨텍스트도 없다.
SELECT rpr_nfa_counters($$
WITH test_reluctant_stats AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_stats
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+?)
    DEFINE
        A AS 'A' = ANY(flags)
)$$);

-- 흡수된 컨텍스트: 같은 행들에 대한 탐욕적 A+ (test_absorbable 와 동일).
-- Pattern 줄은 A+가 흡수 가능함을 표시하고, 2-4 행의 컨텍스트는 1 행의
-- 컨텍스트에 흡수되어 1-4 에 매치한다.
SELECT rpr_nfa_counters($$
WITH test_absorbed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_absorbed
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+)
    DEFINE
        A AS 'A' = ANY(flags)
)$$);

-- SKIP TO NEXT ROW 를 사용한 같은 쿼리: 흡수가 비활성화되므로 패턴에 표시가
-- 없고, 아무것도 흡수되지 않으며, 1-4 행 각각이 자기만의 매치를 얻는다.
SELECT rpr_nfa_counters($$
WITH test_absorbed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_absorbed
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+)
    DEFINE
        A AS 'A' = ANY(flags)
)$$);

-- 건너뛰어진 컨텍스트: A B C 는 흡수 가능하지 않으므로,
-- 1 행의 매치가 3 행에서 끝날 때 2 행과 3 행에서 시작된
-- 컨텍스트는 여전히 살아 있다.  SKIP PAST LAST ROW 는 둘 다
-- skip 된 것으로 해제하고 (길이 2 와 1), 4 행은 매치가 없다.
WITH test_skipped AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A', 'B']),
        (3, ARRAY['A', 'B', 'C']),  -- 1 행에서 시작한 매치를 완료함
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skipped
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);
SELECT rpr_nfa_counters($$
WITH test_skipped AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A', 'B']),
        (3, ARRAY['A', 'B', 'C']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skipped
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
)$$);

-- 같은 행에 SKIP TO NEXT ROW 를 사용: 아무것도 건너뛰어지지 않고, 2 행의
-- 컨텍스트는 자기만의 중첩된 매치 2-4 로 이어진다.
WITH test_skipped AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A', 'B']),
        (3, ARRAY['A', 'B', 'C']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skipped
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);
SELECT rpr_nfa_counters($$
WITH test_skipped AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A', 'B']),
        (3, ARRAY['A', 'B', 'C']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skipped
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
)$$);

DROP FUNCTION rpr_nfa_counters(text);

-- ============================================================
-- 수량자 런타임 동작
-- ============================================================

-- 큰 count 처리 (A{100})
WITH test_large_count AS (
    SELECT i AS id, ARRAY['A'] AS flags
    FROM generate_series(1, 105) i
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_large_count
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A{100})
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 무제한 수량자 (A{10,})
WITH test_unlimited AS (
    SELECT i AS id, ARRAY['A'] AS flags
    FROM generate_series(1, 15) i
    UNION ALL
    SELECT 16, ARRAY['B']
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_unlimited
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A{10,} B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- Min 경계 (A{3,5})
WITH test_min_boundary AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),  -- Min=3 도달, 이탈 경로 가능
        (4, ARRAY['B']),  -- min 에서 매치 종료
        (5, ARRAY['A']),
        (6, ARRAY['A']),
        (7, ARRAY['A']),
        (8, ARRAY['A']),
        (9, ARRAY['A']),  -- Count=5, max 도달
        (10, ARRAY['B'])  -- max 에서 매치 종료
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_min_boundary
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A{3,5} B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- Max 경계 초과 (A{3,5})
WITH test_max_boundary AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['A']),  -- Count=6 > max=5, 1 행의 컨텍스트 제거됨
        (7, ARRAY['B'])   -- 1 행의 컨텍스트: 매치 없음 (max 초과)
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_max_boundary
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A{3,5} B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 탐욕적 대 소극적: A+는 모든 행에 매치하고, A+?는 최소만 매치한다
WITH test_greedy_vs_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','_']),
        (2, ARRAY['A','_']),
        (3, ARRAY['A','B']),
        (4, ARRAY['B','_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_greedy_vs_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 같은 데이터, 소극적 A+?는 B 가 처음 가능한 3 행에서 빠져나간다
WITH test_greedy_vs_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','_']),
        (2, ARRAY['A','_']),
        (3, ARRAY['A','B']),
        (4, ARRAY['B','_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_greedy_vs_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 소극적 그룹: (A B)+?는 최소 1 회 반복만 매치한다
WITH test_reluctant_group AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_group
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B)+?)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- A+? B (소극적 plus): B 가 처음 가능할 때 A 를 빠져나온다
-- (단독 소극적-plus 사례; 아래의 A{1,3}?, A{3,5}?와 비교하라)
WITH test_reluctant_plus AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','_']),
        (2, ARRAY['A','_']),
        (3, ARRAY['A','B']),
        (4, ARRAY['B','_'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_reluctant_plus
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- A{1,3}? B (소극적 bounded): 같은 데이터, bounded 수량자
WITH test_reluctant_bounded AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','_']),
        (2, ARRAY['A','_']),
        (3, ARRAY['A','B']),
        (4, ARRAY['B','_'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_reluctant_bounded
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{1,3}? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- A{3,5}?  B (소극적 bounded 중간대역): VAR 수준의 count 가 하나의 매치 시도
-- 안에서 3, 4, 5 를 순환한다.  흡수성 분석이 제외하는 소극적 bounded 수량자를
-- 검사한다 (소극적 수량자는 결코 흡수 가능하지 않으므로 A 는 흡수 불가능
-- 상태를 유지한다).
WITH test_reluctant_mid_band AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_mid_band
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{3,5}? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 중첩된 수량자 평탄화는 매칭 언어를 넓혀서는 안 된다.  k >= 2 일 때
-- (A{k,})*는 반복 횟수 {0} UNION [k, INF)에 도달한다; 1..k-1 구간은 도달
-- 불가능하므로 A*로 축약되어서는 안 된다.  고립된 단일 A 는 길이-1 매치가
-- 아니라 빈 매치(count 0)를 내야 한다.
WITH test_nested_quant_var AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),  -- 고립된 A: (A{2,})*는 여기서 1 이 아니라
                          -- 빈 매치를 낸다
        (2, ARRAY['_']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),  -- 연속 2 개: 매치됨
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end,
       count(*) OVER w AS match_count
FROM test_nested_quant_var
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A{2,})*)
    DEFINE A AS 'A' = ANY(flags)
);

-- GROUP 자식에서도 마찬가지다: ((A B){2,})*는 (A B)*로 축약되어서는 안 된다.
-- 고립된 단일 (A B) 쌍은 빈 매치(count 0)를 내야 한다.
WITH test_nested_quant_group AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),  -- 고립된 (A B) 쌍: 여기서 빈 매치를 낸다
        (2, ARRAY['B']),
        (3, ARRAY['_']),
        (4, ARRAY['A']),
        (5, ARRAY['B']),
        (6, ARRAY['A']),
        (7, ARRAY['B']),  -- 연속 2 개 쌍: 매치됨
        (8, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end,
       count(*) OVER w AS match_count
FROM test_nested_quant_group
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A B){2,})*)
    DEFINE A AS 'A' = ANY(flags), B AS 'B' = ANY(flags)
);

-- 본체 선두의 선택적 VAR 가 반복에 걸쳐 재진입됨: B 행이 없는 (B? A+){2}.  두
-- 반복 모두 B 를 건너뛰고 A 로 재진입한다.
WITH test_optvar_quant_reentry AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_optvar_quant_reentry
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((B? A+){2})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 그룹의 END 에 떨어지는 skip 경로도 그 반복을 count 한다: 상승 구간에 걸친
-- (UP DOWN?)+이며, DOWN 은 결코 매치되지 않는다.
WITH test_skip_lands_on_end AS (
    SELECT * FROM (VALUES
        (1, 100),
        (2, 110),
        (3, 120)
    ) AS t(id, price)
)
SELECT id, price,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skip_lands_on_end
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((UP DOWN?)+)
    DEFINE
        UP AS price > PREV(price),
        DOWN AS price < PREV(price)
);

-- 깊은 giveback: A+가 중첩되는 모든 행을 삼킨 뒤 B{3}가 실패하여 A+는 연속으로
-- 세 행을 내주어야 한다.  실패는 분기 지점에 인접해서가 아니라 그로부터 다섯
-- 행 떨어진 곳에서 발견된다.
WITH test_quant_deep_giveback AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['A','B']),
        (3, ARRAY['A','B']),
        (4, ARRAY['A','B']),
        (5, ARRAY['A','B']),
        (6, ARRAY['A','B']),
        (7, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_deep_giveback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B{3} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 모두 A 이면서 B 인 행들에 걸친 A+ B+ A+: 세 수량자가 하나의 풀에서
-- 끌어오므로, 첫 번째를 줄이면 나머지 둘이 취할 수 있는 것이 달라진다.  이들은
-- 하나씩이 아니라 함께 재협상해야 한다.
WITH test_quant_coupled_spans AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['A','B']),
        (3, ARRAY['A','B']),
        (4, ARRAY['A','B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_coupled_spans
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B+ A+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- 병적(pathological) 패턴 런타임 보호
-- ============================================================

-- 복잡하게 중첩된 nullable ((A* B*)*) - 런타임 보호
WITH test_complex_nested AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['B']),
        (5, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_complex_nested
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A* B*)*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 수량자가 있는 중첩된 nullable ((A{0,3})*)
WITH test_nested_quantifier AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_quantifier
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A{0,3})*)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 소극적 nullable: A*? (0 회 매치를 선호한다)
-- A*?는 skip 경로를 먼저 시도한다; 여기엔
-- B 인 행이 없으므로 아무것도 매치되지 않는다
WITH test_reluctant_nullable AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_nullable
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A*? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 연속된 그룹은 본체의 행 수가 고정된 경우에만 병합된다.  (A | B B)+
-- (A | B B)+는 두 그룹을 그대로 유지한다: 병합된 (A | B B){2,}는 두 행 이후
-- 멈출 것이다.  두 번 반복하면 이미 하한을 충족하기 때문인데, 여기서는 두 번째
-- 그룹이 여전히 자기만의 반복을 요구한다.
WITH test_group_merge_uneven_alt AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A', 'B']),
        (3, ARRAY['B']),
        (4, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_group_merge_uneven_alt
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B B)+ (A | B B)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 같은 가드를 본체 안의 소극적 수량자를 통해서도 검사한다: B A+?도 마찬가지로
-- 고정된 행 수를 가지지 않으므로 (B A+?)+ (B A+?)+는 그대로 유지된다.
WITH test_group_merge_reluctant_body AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['B']),
        (7, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_group_merge_reluctant_body
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((B A+?)+ (B A+?)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A | B B){1,2} (A | B B)의 뒤따르는 복사본도 같은 이유로 그룹에 접히지
-- 않는다.  선행 복사본이었다면 필수적이므로 접혔을 것이다.
WITH test_suffix_merge_uneven_alt AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A', 'B']),
        (3, ARRAY['B']),
        (4, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_suffix_merge_uneven_alt
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B B){1,2} (A | B B))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 중첩된 bounded 수량자 ((A{2,3}){1,2})는 A{2,6}으로 평탄화되지 않는다: 첫
-- 반복의 count 는 그룹이 다시 반복할지 결정하기 전에 확정되므로, A 행이 네 개
-- 있을 때 둘씩 둘로 나누지 않고 세 개를 취한 뒤 그룹을 떠난다.  A{2,6}이라면
-- 네 개를 모두 취했을 것이다.
WITH test_nested_bounded_quantifier AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_bounded_quantifier
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A{2,3}){1,2})
    DEFINE
        A AS 'A' = ANY(flags)
);

-- ============================================================
-- 교대 런타임 동작
-- ============================================================

-- 다중 분기 교대 (A (B|C|D|E) F)
WITH test_multi_branch AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['F']),
        (4, ARRAY['A']),
        (5, ARRAY['C']),
        (6, ARRAY['F']),
        (7, ARRAY['A']),
        (8, ARRAY['D']),
        (9, ARRAY['F']),
        (10, ARRAY['A']),
        (11, ARRAY['E']),
        (12, ARRAY['F'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_multi_branch
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A (B | C | D | E) F)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags),
        F AS 'F' = ANY(flags)
);

-- 수량자가 있는 교대 (A+ | B+ | C+)
WITH test_alt_quantifiers AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['B']),
        (6, ARRAY['C']),
        (7, ARRAY['C']),
        (8, ARRAY['C']),
        (9, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_quantifiers
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ | B+ | C+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 분기 선호 (A B C | D): D 는 1 행에서 먼저 완료되지만, 먼저 작성된 A B C
-- 분기가 선호되어 3 행의 매치를 대체한다.
WITH test_alt_replace AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A', 'D']),
        (2, ARRAY['B', '_']),
        (3, ARRAY['C', '_']),
        (4, ARRAY['_', '_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_replace
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C | D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- ALT 의 Lexical Order 가 탐욕적(더 긴 매치)보다 우선한다.
-- 1 행은 A 와 B 에 모두 매치한다; A 가 Lexical Order 에 의해 이긴다
-- (매치 1-1).
WITH test_alt_lexical_order AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),  -- A 와 B 가 모두 매치됨
        (2, ARRAY['_','C'])   -- C 만 매치됨 (B C 로 이어졌을 것이다)
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_lexical_order
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B C)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 선호되는 분기가 빈 매치를 내더라도 선호는 길이를 이긴다: A* 분기는
-- 행을 하나도 소비하지 않고 FIN 에 도달하고 nfa_advance_alt 는
-- 거기서 멈추므로, B 가 매치했을 행에서도 B 는 전개되지 않는다.
WITH test_alt_empty_pref AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A', 'B']),
        (2, ARRAY['_', 'B']),
        (3, ARRAY['A', 'B']),
        (4, ARRAY['_', 'B'])
    ) AS t(id, flags)
)
SELECT id, flags, count(*) OVER w AS n
FROM test_alt_empty_pref
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A* | B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 분기를 바꾸면 B 가 선호되므로, 모든 행이 한 행씩 매치한다.
WITH test_alt_empty_pref AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A', 'B']),
        (2, ARRAY['_', 'B']),
        (3, ARRAY['A', 'B']),
        (4, ARRAY['_', 'B'])
    ) AS t(id, flags)
)
SELECT id, flags, count(*) OVER w AS n
FROM test_alt_empty_pref
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (B | A*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 소극적을 포함한 ALT: (A+? | B+) - A 분기는 소극적이고 B 는 탐욕적이다.  1
-- 행은 A 와 B 에 모두 매치한다.  A+?는 즉시 빠져나간다 (매치 1-1).
WITH test_alt_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['B','_']),
        (3, ARRAY['B','_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+? | B+))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 수량자가 있는 ALT 의 선택적 첫 분기: (A? | B){1,2} 첫 분기 A?의 이탈 경로는
-- ALT 로 loop-back 할 수 있으며 DFS 동안 사이클 감지를 유발할 수 있다.  B
-- 행에서도 A?  분기는 빈 매치로 성공하며, 이는 B 분기보다 순위가 높으므로
-- 매치는 빈 매치가 된다.
WITH test_alt_opt_first AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_opt_first
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A? | B){1,2}))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A? | B){1,2}의 반복에 걸쳐 A/B 행이 섞임
WITH test_alt_opt_mixed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A','B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_opt_mixed
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A? | B){1,2}))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 소극적 변형: (A?? | B){1,2}
WITH test_alt_opt_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_opt_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A?? | B){1,2}))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 중첩되는 매치: A B C D E | B C D | C D E F (SKIP PAST LAST ROW)
WITH test_overlap1 AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['D']),
        (5, ARRAY['E']),
        (6, ARRAY['F'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_overlap1
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B C D E | B C D | C D E F)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags),
        F AS 'F' = ANY(flags)
);

-- SKIP TO NEXT ROW 를 사용한 같은 경우: 세 개의 중첩되는 매치
WITH test_overlap1 AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['D']),
        (5, ARRAY['E']),
        (6, ARRAY['F'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_overlap1
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C D E | B C D | C D E F)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags),
        F AS 'F' = ANY(flags)
);

-- 긴 패턴은 실패하고 짧은 패턴이 살아남는다: A+ B C D E | B+ C
WITH test_overlap1b AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['D']),
        (5, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_overlap1b
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B C D E | B+ C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags)
);

-- 끝맺음이 다른 긴 B 시퀀스: A B+ C | B+ D
WITH test_overlap2 AS (
    SELECT * FROM (VALUES
        (1,  ARRAY['A']),
        (2,  ARRAY['B']),
        (3,  ARRAY['B']),
        (4,  ARRAY['B']),
        (5,  ARRAY['B']),
        (6,  ARRAY['C']),
        (7,  ARRAY['B']),
        (8,  ARRAY['B']),
        (9,  ARRAY['B']),
        (10, ARRAY['D'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_overlap2
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B+ C | B+ D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 늦은 실패를 동반한 탐욕적 매칭 ("betrayal"): A B C+ D | A B
WITH test_betrayal AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['C']),
        (5, ARRAY['C']),
        (6, ARRAY['E'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_betrayal
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B C+ D | A B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 행당 여러 개의 TRUE: 중첩되는 패턴 변수
WITH test_multi_true AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['B','C']),
        (3, ARRAY['C','D']),
        (4, ARRAY['D','E']),
        (5, ARRAY['E','_'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_multi_true
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B C D E)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags)
);

-- 이동된 다중-TRUE 중첩을 가진 대각선 패턴
WITH test_diagonal AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','_']),
        (2, ARRAY['B','A']),
        (3, ARRAY['C','B']),
        (4, ARRAY['D','C']),
        (5, ARRAY['_','D'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_diagonal
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- ((A | B) C)+ - 외부 수량자를 가진 그룹 안의 교대
WITH test_alt_group AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['C']),
        (3, ARRAY['B']),
        (4, ARRAY['C']),
        (5, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_alt_group
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A | B) C)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- (A | (B C)+ (D E)+): 마지막 분기는 (B C)+ (D E)+이므로,
-- A/B/C 가 없으면 D E D E 행은 아무것도 매치하지 않는다 --
-- 뒤따르는 (D E)+는 자신만의 분기가 아니다.
WITH test_alt_concat_groups AS (
    SELECT * FROM (VALUES
        (1, ARRAY['D']),
        (2, ARRAY['E']),
        (3, ARRAY['D']),
        (4, ARRAY['E'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_concat_groups
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A | (B C)+ (D E)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags),
        E AS 'E' = ANY(flags)
);

-- (A | (B C)*): 마지막 ALT 분기로서의 선택적 그룹.  (B C)*가 0 회 매치하면
-- 분기는 빈 매치로 끝난다 (NULL bounds), 행을 소비하지 않는다.
WITH test_alt_tail_optgroup AS (
    SELECT * FROM (VALUES
        (1, ARRAY['_']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_tail_optgroup
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A | (B C)*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ((B C)* | A): 마지막이 아닌 분기로서의 선택적 그룹.  B C 가 시작하는
-- 곳에서는 그룹이 이를 소비하고 (2 행); 그 밖의 곳에서도 분기는 0 회 매치로
-- 여전히 성공하며, 이는 A 분기보다 순위가 높으므로 A 는 결코 발동하지 않는다
-- (4 행).
WITH test_alt_nonlast_optgroup AS (
    SELECT * FROM (VALUES
        (1, ARRAY['_']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_nonlast_optgroup
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((B C)* | A)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- (((B C)* | A) D): ALT 뒤에 D 가 오므로, 0 회 매치인 (B C)*는 D 로 이어져야
-- 한다.  4 행(단독 D)이 이를 검사한다; 1 행은 B C D 매치다.
WITH test_alt_optgroup_then_elem AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['C']),
        (3, ARRAY['D']),
        (4, ARRAY['D']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_optgroup_then_elem
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((B C)* | A) D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- ((B C)* D | A): 마지막이 아닌 분기 안의 같은 그룹이며, 그 분기 안에서 D 가
-- 뒤따른다.  0 회 매치인 (B C)*는 A 분기로 빠지지 않고 D 로 이어져야 한다; 4
-- 행(단독 D)이 둘을 구별해 주는 행이다.
WITH test_alt_nonlast_grp_then_elem AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['C']),
        (3, ARRAY['D']),
        (4, ARRAY['D']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_nonlast_grp_then_elem
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((B C)* D | A)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- ((B C)*? | A): 분기로서의 소극적 선택적 그룹은 0 회 반복을 선호하므로, 첫
-- 분기가 모든 행에서 빈 매치를 내고 A 분기는 결코 발동하지 않는다.
WITH test_alt_reluctant_optgroup AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['C']),
        (3, ARRAY['A']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_reluctant_optgroup
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((B C)*? | A)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 같은 변수가 반복에 걸쳐 재진입됨: 모두 A 인 파티션에 대한 (A+ | B){2}.  두
-- 반복 모두 A+ 분기를 취하므로, 두 번째 반복은 더 높은 반복 count 로 VAR A 에
-- 재진입한다 -- 이는 사이클이 아니라 새로운 상태다.
WITH test_alt_quant_reentry AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_quant_reentry
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((A+ | B){2})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 분기 순서는 매치를 바꾸지 않는다: (B | A+){2}도 동일하다.
WITH test_alt_quant_reentry_order AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_quant_reentry_order
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((B | A+){2})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 손으로 풀어 쓴 형태.  mergeConsecutiveAlts 가 이를 다시 {2}로 말아 올리므로,
-- 매치는 위의 두 경우와 같아야 한다.
WITH test_alt_quant_unrolled AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_quant_unrolled
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((A+ | B) (A+ | B))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 두 분기 모두 폭이 2 행이고 모든 행을 공유하는 ((A B) | (C D))+: 한 반복에서
-- 취한 분기가 다음 반복에 남는 행을 결정한다.
WITH test_alt_multirow_branches AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','C']),
        (2, ARRAY['B','D']),
        (3, ARRAY['A','C']),
        (4, ARRAY['B','D']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_multirow_branches
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A B) | (C D))+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 같은 행이지만 분기를 반대 순서로 작성함.  여기서는
-- 두 분기 모두 같은 행에 매치하므로 결과가 바뀌어서는
-- 안 된다: 분류는 바뀌지만 프레임은 바뀌지 않는다.
WITH test_alt_multirow_swapped AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','C']),
        (2, ARRAY['B','D']),
        (3, ARRAY['A','C']),
        (4, ARRAY['B','D']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_multirow_swapped
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((C D) | (A B))+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- ============================================================
-- 깊이 중첩된 그룹
-- ============================================================

-- 3 단계 중첩 ((((A B)+)+)+)
WITH test_deep_nesting AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B']),
        (7, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_deep_nesting
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((((A B)+)+)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 중첩 안의 여러 그룹 (((A B) (C D))+)
WITH test_nested_sequential AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['D']),
        (5, ARRAY['A']),
        (6, ARRAY['B']),
        (7, ARRAY['C']),
        (8, ARRAY['D']),
        (9, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_sequential
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A B) (C D))+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 중첩된 END->END max 도달
-- 내부 그룹 (A B){2}가 max=2 에 도달함 -> 외부 END 로 빠져나간다
WITH test_end_nested_max AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B']),
        (7, ARRAY['A']),
        (8, ARRAY['B']),
        (9, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_end_nested_max
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A B){2})+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ((A B){1,3})+: 옵티마이저에 의해 (A B)+로 평탄화되므로 그룹 수준이 하나만
-- 실행된다; 중첩된 표기에 대한 결과 검사용으로 둔다
WITH test_end_nested_mid AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B']),
        (7, ARRAY['A']),
        (8, ARRAY['B']),
        (9, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_end_nested_mid
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A B){1,3})+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 뒤따르는 요소 C 를 가진 소극적 그룹 (A B)+?
-- 그룹은 매 반복 후 빠져나가려 시도한다: 1 행에서는 3 행이 C 가 아니므로
-- 두 번째 반복을 취한다 (1-5); 3 행에서는 한 번으로 충분하다 (3-5)
WITH test_nested_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A B)+? C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- (A B){2} - 정확한 수량자를 가진 그룹
WITH test_group_exact AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['X'])
    ) AS t(id, flags)
)
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM test_group_exact
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B){2})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 중첩된 nullable 그룹: ((A?){2,3}){2,3}
-- 자식의 min 이 두 단계 모두 0 이므로 옵티마이저가 이들을
-- 곱하여 A{0,9}로 실행한다: 그룹 END 나 fast-forward 경로는 남지
-- 않는다.  데이터에 A 행이 없으므로 모든 행이 빈 매치를 낸다.
WITH test_nested_ff AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_ff
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A?){2,3}){2,3})
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 가변 길이 본체에 대한 정확한 외부 수량자
-- (X{1,2}){2}는 정의상 X{1,2} X{1,2}이므로, 둘은 같은 매치를 선호해야 한다.
-- (A | B B){2,4}로의 축약은 그렇지 않다: 분기들이 서로 다른 행 수를
-- 소비하므로, 반복을 블록 경계 너머로 옮기면 어떤 행이 매치되는지가 달라진다.
-- 아래의 세 번째 쿼리는 축약된 형태 자체의 선호를 보여준다.
WITH test_nested_alt_body AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B']),
        (4, ARRAY['A']),
        (5, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_alt_body
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A | B B){1,2}){2})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 같은 패턴을 풀어 쓴 것. 중첩된 형태와 같은 매치를 내야 한다.
WITH test_nested_alt_body AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B']),
        (4, ARRAY['A']),
        (5, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_alt_body
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B B){1,2} (A | B B){1,2})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 손으로 작성한 축약된 형태: 위 두 경우와 같은 반복 횟수를 가지지만, 두 번째
-- 반복을 강제하는 블록 경계가 없으므로 1-2 행에서 멈춘다. 이 차이가 위의 두
-- 경우를 이 형태로 다시 작성해서는 안 되는 이유다.
WITH test_nested_alt_body AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B']),
        (4, ARRAY['A']),
        (5, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nested_alt_body
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B B){2,4})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 본체가 항상 행을 소비하는 그룹으로의 재진입
-- 빈 매치를 낼 수 없는 본체는 모든 유도에서 행을 소비하므로, 그
-- 안으로의 loop-back 은 사이클이 아니라 진행이다.  두 형태 모두
-- 같은 매치를 찾아야 한다: (X){3}은 정의상 X X X 다.
WITH test_reentry_consuming AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['A','B']),
        (7, ARRAY['B']),
        (8, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reentry_consuming
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A | B B){1,3}){3})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 같은 패턴을 풀어 쓴 것. 중첩된 형태와 같은 매치를 내야 한다.
WITH test_reentry_consuming AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['A','B']),
        (7, ARRAY['B']),
        (8, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reentry_consuming
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B B){1,3} (A | B B){1,3} (A | B B){1,3})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- min 미만에서 빈 반복 뒤에 소비하는 반복이 이어짐
-- A?가 B 보다 먼저 시도되므로, 1 행에서 처음 두 반복은 빈 매치가
-- 되고 세 번째가 B 를 취해 1-2 행에 매치한다.  더 긴 A B C 매치는
-- 순위가 낮다: 첫 반복에서 A?를 포기하기 때문이다
-- (7.2.4 -- 길이는 접두 동률만 깬다).
WITH test_empty_then_consume AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A','C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_empty_then_consume
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A? | B){3} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 같은 패턴을 풀어 쓴 것이며, 어떤 재작성도 이를 다시 루프로 접어 넣을 수
-- 없도록 복사본의 이름을 바꾸었다.  같은 매치를 내야 한다.
WITH test_empty_then_consume AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A','C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_empty_then_consume
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A? | B) (D? | E) (F? | G) C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'A' = ANY(flags),
        E AS 'B' = ANY(flags),
        F AS 'A' = ANY(flags),
        G AS 'B' = ANY(flags)
);

-- 위의 빈-후-소비 사례들보다 높은 경계.  2 이상의 모든 경계에서 행은 같지만
-- 유도는 바뀌므로, min 미만 count 를 통한 지름길이 여기서 처음 나타난다.
-- 여기서는 그것들이 인접해 있지 않다.
WITH test_empty_then_consume_bound AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A']),
        (3, ARRAY['A','C']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_empty_then_consume_bound
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A? | B){4} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 같은 min 미만 경로의 재귀 깊이: fall-through 는 한 번에 하나의 빈 반복만큼
-- count 를 전진시키므로 깊이는 경계를 따른다.  스택을 줄여 한계에 빨리
-- 도달하게 한다.
SET max_stack_depth = '100kB';
WITH test_below_min_depth AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A','C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_below_min_depth
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A? | B){10000} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);
RESET max_stack_depth;

-- 중첩 행이 있는 (A+)+ B: 내부 A+는 3 행을 A 로 취해야 하며, 4 행은 B 를 위해
-- 남긴다.  수량자가 붙은 변수와 그 다음 변수를 모두 만족하는 행에 걸친 중첩된
-- 무제한 수량자.
WITH test_nest_unbounded_overlap AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A','B']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nest_unbounded_overlap
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A+)+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ((A+ B)+ C)+ D: 세 깊이에 있는 세 개의 무제한
-- 수량자이며, 모든 행이 다음 행과 공유된다.  각 수준의
-- 반복 경계는 같은 행들 위에서 여러 방식으로 그을 수 있다.
WITH test_nest_three_levels AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B','C']),
        (4, ARRAY['C','D']),
        (5, ARRAY['D'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nest_three_levels
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A+ B)+ C)+ D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- ((A | B)+)+ C: 두 개의 무제한 수량자 안에 중첩된 교대이며, 두 대안을 모두
-- 만족하는 행을 가진다.
WITH test_nest_alt_unbounded AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B','C']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nest_alt_unbounded
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (((A | B)+)+ C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ============================================================
-- SKIP 옵션 (런타임)
-- ============================================================

-- SKIP PAST LAST ROW (중첩되지 않는 매치)
WITH test_skip_past AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skip_past
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- SKIP TO NEXT ROW (중첩되는 매치)
WITH test_skip_next AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skip_next
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- SKIP 차이 검증
WITH test_skip_diff AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT 'SKIP PAST' AS mode, id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skip_diff
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
)
UNION ALL
SELECT 'SKIP NEXT' AS mode, id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skip_diff
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
)
ORDER BY mode, id;

-- 소극적 SKIP 비교: SKIP PAST 대 SKIP NEXT 를 사용하는 A+?
WITH test_reluctant_skip AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT 'SKIP PAST' AS mode, id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_skip
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+?)
    DEFINE
        A AS 'A' = ANY(flags)
)
UNION ALL
SELECT 'SKIP NEXT' AS mode, id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_skip
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+?)
    DEFINE
        A AS 'A' = ANY(flags)
)
ORDER BY mode, id;

-- SKIP PAST LAST ROW 아래에서의 A*: 1 행은 빈 매치를 내는데, 이는 아무것도
-- 소비하지 않으므로 skip 착지점을 옮겨서는 안 된다.  2 행은 여전히 자기만의
-- 매치를 시작한다.
WITH test_skip_past_after_empty AS (
    SELECT * FROM (VALUES
        (1, ARRAY['_']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skip_past_after_empty
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A*)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- (A B)* C: 1 행은 그룹을 0 회 취한 채 C 만으로 매치하므로, 착지점은 2 행이고
-- 2-4 행의 A B C 매치는 여전히 찾아진다.
WITH test_skip_past_zero_iterations AS (
    SELECT * FROM (VALUES
        (1, ARRAY['C']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_skip_past_zero_iterations
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B)* C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ============================================================
-- INITIAL 모드 (런타임)
-- ============================================================

-- 명시적 INITIAL (문법에 따라 AFTER MATCH SKIP 뒤에 옴); 기본값과 동일
WITH test_initial_mode AS (
    SELECT * FROM (VALUES
        (1, ARRAY['_']),  -- 매치되지 않음
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['_']),  -- 매치되지 않음
        (5, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_initial_mode
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    INITIAL
    PATTERN (A+)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 기본 모드 (모든 행 포함)
WITH test_default_mode AS (
    SELECT * FROM (VALUES
        (1, ARRAY['_']),  -- 매치되지 않았지만 포함됨
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['_']),  -- 매치되지 않았지만 포함됨
        (5, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_default_mode
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 모드 동등성 검증: 명시적 INITIAL 은 기본 모드와 같다
WITH test_mode_diff AS (
    SELECT * FROM (VALUES
        (1, ARRAY['_']),
        (2, ARRAY['A']),
        (3, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT 'INITIAL' AS mode, COUNT(*) AS row_count
FROM (
    SELECT id FROM test_mode_diff
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP TO NEXT ROW
        INITIAL
        PATTERN (A)
        DEFINE A AS 'A' = ANY(flags)
    )
) sub
UNION ALL
SELECT 'DEFAULT' AS mode, COUNT(*) AS row_count
FROM (
    SELECT id FROM test_mode_diff
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP TO NEXT ROW
        PATTERN (A)
        DEFINE A AS 'A' = ANY(flags)
    )
) sub
ORDER BY mode;

-- ============================================================
-- 프레임 경계 변형
-- ============================================================

-- 매우 제한된 프레임 (1 FOLLOWING)
WITH test_one_following AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),  -- 1 FOLLOWING 이내
        (3, ARRAY['A']),  -- 1 행 기준 1 FOLLOWING 을 벗어남
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_one_following
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 중간 크기 프레임 (10 FOLLOWING)
WITH test_ten_following AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['A']),
        (7, ARRAY['A']),
        (8, ARRAY['A']),
        (9, ARRAY['A']),
        (10, ARRAY['A']),
        (11, ARRAY['B']),  -- 1 행 기준 10 FOLLOWING 이내
        (12, ARRAY['A']),
        (13, ARRAY['B'])   -- 1 행 기준 10 FOLLOWING 을 벗어남
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_ten_following
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 10 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 정확한 경계 매치
WITH test_exact_boundary AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['B'])   -- 정확히 4 FOLLOWING (프레임 끝)
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_exact_boundary
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 4 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- N FOLLOWING + SKIP TO NEXT ROW: 프레임에 의해 제한되는 중첩 매치
WITH test_n_skip_next AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_n_skip_next
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 3 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 잠재적 매치보다 정확히 1 행 부족한 프레임
-- 1 행부터: A A A B 는 4 행이 필요하지만 프레임은 3 행만 가진다 -> 매치 없음
-- 2 행부터: A A B 는 3-행 프레임에 들어맞는다 -> 매치
WITH test_frame_one_short AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_frame_one_short
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- 특수 파티션 사례
-- ============================================================

-- 빈 파티션 (0 행)
WITH test_empty_partition AS (
    SELECT * FROM (VALUES
        (1, 1, ARRAY['A']),
        (2, 2, ARRAY['_'])  -- 다른 파티션
    ) AS t(id, part, flags)
)
SELECT id, part, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_empty_partition
WHERE part = 99  -- 매치되는 행 없음
WINDOW w AS (
    PARTITION BY part
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 단일 행 파티션
WITH test_single_row AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_single_row
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- 모든 행이 매치에 실패함 (모든 DEFINE false)
WITH test_all_fail AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_all_fail
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+)
    DEFINE
        A AS false  -- 모든 행이 실패함
);

-- 흡수 가능한 패턴에서의 파티션 끝
-- SKIP PAST LAST ROW + 무제한 프레임 + 모든 행이 A 에
-- 매치 더 새로운 컨텍스트는 행마다 흡수된다; 파티션 끝의
-- !rpr_prepare_row() 경로는 남은 컨텍스트를 확정하기만 한다.
WITH test_absorb_partition_end AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_absorb_partition_end
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- ============================================================
-- DEFINE 특수 사례
-- ============================================================

-- DEFINE 에 정의되지 않은 변수
WITH test_undefined_var AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['X']),  -- B 가 정의되지 않음, 기본값 TRUE
        (3, ARRAY['C']),
        (4, ARRAY['A']),
        (5, ARRAY['_']),  -- B 는 기본값 TRUE 지만 플래그가 없음
        (6, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_undefined_var
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C)
    DEFINE
        A AS 'A' = ANY(flags),
        -- B 는 정의되지 않음, 기본값 TRUE
        C AS 'C' = ANY(flags)
);

-- ============================================================
-- 흡수 동적 플래그
-- ============================================================

-- 부분적으로 흡수 가능한 패턴 ((A+) B)
-- 각 A 행의 advance 는 A+ 옆에 흡수 불가능한 B 상태를 추가한다; 이는
-- absorb 단계 전에 다음 A 행에서 소멸하므로, 2-3 행의 컨텍스트는
-- 여전히 흡수된다.  4 행의 컨텍스트는 1-4 매치에 의해 건너뛰어진다.
WITH test_partial_absorbable AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_partial_absorbable
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+) B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 동적 플래그 갱신 ((A+) | B)
-- 새 컨텍스트는 두 분기 모두에 상태를 가진 채 시작한다; B 상태가
-- 소멸하면 흡수 가능해지므로 2-3 행은 1-3 매치에 흡수된다.  이어서
-- 4 행과 6 행은 B 를 통해 매치하고, 5 행은 단독으로 A+를 통해 매치한다.
WITH test_dynamic_flags AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_dynamic_flags
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+) | B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 흡수 도중의 흡수 불가능한 컨텍스트
-- 패턴 (A B)+ C: A, B 는 흡수 가능한 그룹에 있고 C 는 아니다.
-- END 가 C 로 빠져나갈 때, 복제된 상태는 흡수 불가능해진다.
WITH test_non_absorbable AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['C']),
        (6, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_non_absorbable
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B)+ C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 흡수 가능한 상태가 남지 않으면 흡수를 건너뛴다
-- SKIP PAST LAST ROW 를 사용하는 패턴 (A B)+ C D
-- (흡수 불가능한) C 에 도달한 뒤에는 흡수 가능한 상태가 남지
-- 않는다.  다음 행(D)에서 조기 반환(early return)이 발동한다.
WITH test_absorption_early_return AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['C']),
        (6, ARRAY['D']),
        (7, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_absorption_early_return
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B)+ C D)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- 커버리지 실패: 더 오래된 것이 더 새로운 것의 상태를 커버할 수 없음
-- SKIP PAST LAST ROW 를 사용하는 패턴 A+ | B+.
-- 1 행: A 만 -> Ctx1 은 A 분기만 취한다 (B 는 실패).
-- 2 행: A 와 B -> Ctx2 는 두 분기를 모두 취한다.  흡수: Ctx1 은
-- A 는 있지만 B 가 없다 -> Ctx2 의 B 상태를 커버할 수 없다 -> 실패.
WITH test_coverage_fail AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A', '_']),
        (2, ARRAY['A', 'B']),
        (3, ARRAY['A', '_']),
        (4, ARRAY['A', '_']),
        (5, ARRAY['_', '_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_coverage_fail
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ | B+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- Absorb 는 완료된 컨텍스트를 건너뛴다 (older->states==NULL)
-- SKIP PAST LAST ROW 를 사용하는 패턴 A+ | B+.
-- 1 행: A 만 -> Ctx1 은 A 분기를 취한다.
-- 2 행: B 만 -> Ctx1 의 A 는 실패한다 (완료됨).
-- Ctx2 는 B 분기를 취한다. 흡수: Ctx1 의 states==NULL -> 건너뜀.
WITH test_older_completed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['B']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_older_completed
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ | B+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- Absorb 는 흡수 가능한 상태가 없는 컨텍스트를 건너뛴다
-- SKIP PAST LAST ROW 를 사용하는 패턴 A+ | B C (A+ 분기만 흡수 가능).  1 행:
-- B 만 -> Ctx1 은 B 분기를 취하고 (흡수 불가능), C 로 전진한다.  2 행: C, A ->
-- Ctx1 의 C 가 매치한다 (흡수 가능한 상태 없음).  Ctx2 는 A 를 취한다
-- (흡수 가능).  흡수: Ctx1 은 흡수 가능한 상태가 없다 -> 건너뜀.
WITH test_older_non_absorbable AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B', '_']),
        (2, ARRAY['C', 'A']),
        (3, ARRAY['_', 'A']),
        (4, ARRAY['_', '_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_older_non_absorbable
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ | B C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ALT 안의 소극적 분기는 흡수 불가능하다: (A+?) | B
-- A+?는 소극적이므로 SKIP PAST LAST ROW 를 쓰더라도 흡수 불가능하다.  위의
-- 탐욕적 (A+) | B 와 비교하라: 여기서는 1-4 행이 각각 한 행씩 매치한다.
WITH test_reluctant_alt_absorption AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_reluctant_alt_absorption
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+?) | B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- 영-소모 사이클 감지
-- ============================================================

-- (A*)*: 옵티마이저에 의해 A*로 평탄화되므로 그룹 END 도 사이클 가드도
-- 관여하지 않는다; 중첩된 표기에 대한 결과 검사용으로 둔다
WITH test_cycle_nonzero AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B'])  -- A*는 여기서 멈춘다
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_cycle_nonzero
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A*)*)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- nullable 이 섞인 사이클: (A* B*)*, 여러 nullable 경로
WITH test_cycle_mixed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_cycle_mixed
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A* B*)*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A (B*?)+?)+ : 외부 수량자 안에서 nullable 그룹에 걸친 소극적 무제한 수량자.
-- 빈 반복이 내부 루프를 끝낸다.
WITH test_cycle_reluctant_nullable AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_cycle_reluctant_nullable
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A (B*?)+?)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 하한이 0 인 bounded 외부 수량자 아래의 같은 본체.
WITH test_cycle_reluctant_bounded AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_cycle_reluctant_bounded
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A (B*?)+?){0,2})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 같은 nullable 그룹에 대한 탐욕적 내부: 선호되는 경로는 행을 소비하고
-- frontier 에 머무르므로, epsilon 을 통해 재귀할 수 없다.
WITH test_cycle_greedy_nullable AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_cycle_greedy_nullable
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A (B*?)+){2,})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- nullable 하지 않은 내부 본체: 모든 유도가 행을 소비하므로 빈 반복이 존재하지
-- 않고 가드가 할 일이 없다.
WITH test_cycle_nonnullable_inner AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_cycle_nonnullable_inner
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A (B+)+?){2,})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 하한이 1 보다 큰 외부 수량자 안에서, nullable 그룹에 걸친 소극적 무제한
-- 수량자.  경계 미만에서는 가드가 무제한 epsilon 재귀 없이 계속 루프를 돌아야
-- 한다: 빈 내부 반복마다 경계에 도달할 때까지 count 를 전진시킨다.  두 번의
-- 반복(각각 A 하나, 내부는 빈 매치)이 min=2 를 충족하며 1-2 행에 매치한다.
WITH test_cycle_reluctant_below_min AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_cycle_reluctant_below_min
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A (B*?)+?){2,})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 소극적 외부 경계를 가진 같은 형태: 세 번째 A 행이 있더라도 정확히 두 번의
-- 반복에서 멈춘다.
WITH test_cycle_reluctant_outer_min AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_cycle_reluctant_outer_min
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A (B*?)+?){2,}?)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ------------------------------------------------------------
-- 우선성 가드: 두 번째로 탐색되는 경로는 첫 번째가 이미 기록한 매치를
-- 덮어써서는 안 된다
-- ------------------------------------------------------------
--
-- 두 경로가 같은 요소를 떠날 때 먼저인 쪽이 선호되는 경로이므로, 그것이 매치를
-- 기록한 뒤에는 두 번째가 실행되어서는 안 된다.  아래에서 두 유도는 같은 행을
-- 커버하므로 어느 쪽이든 출력은 같다; 가드를 제거했을 때 실패하는 것은 cassert
-- 빌드에서의 어서션이다.

-- 그룹을 건너뛰기 전에 먼저 진입한다.
WITH test_guard_begin_enter AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_guard_begin_enter
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A (B*?)*){1,3})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 하한 미만에서, fast-forward 전에 먼저 loop-back 한다.
WITH test_guard_end_below_min AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_guard_end_below_min
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? B?){3,4})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 경계 사이에서, 이탈 전에 먼저 loop 한다.  여기서는 두 번째 경로가 FIN 에
-- 도달하는 대신 상태를 park 한다.
WITH test_guard_end_loop_exit AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_guard_end_loop_exit
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A (B*?)+){2,3})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- 표준 절 7: 형식적 패턴 매칭 규칙
-- ISO/IEC 19075-5, 절 7
-- ============================================================

-- ------------------------------------------------------------
-- 7.2.2 교대: 첫 번째 대안이 선호된다
-- ------------------------------------------------------------

-- (A | B): 둘 다 매치할 수 있을 때 A 가 B 보다 선호된다
-- 1 행은 A 와 B 플래그를 모두 가진다: A 가 선택되어야 한다 (첫 번째 대안)
WITH test_alt_prefer AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['B']),
        (3, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_prefer
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A | B))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A{1,2} | B{2,3}): 모든 B-매치보다 먼저 모든 A-매치
-- 표준 예제: 우선성 순서는 AA, A, BBB, BB 이다
-- 1-2 행은 A 와 B 를 모두 가진다: 탐욕적 A{1,2}는 1-2 에 매치해야 한다
WITH test_alt_quantified AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['A','B']),
        (3, ARRAY['B']),
        (4, ARRAY['B']),
        (5, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_quantified
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A{1,2} | B{2,3}))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A | B B | C C C): 세 개의 대안이며 모든 행에서
-- 모두 가능하다.  우선성 순서는 A, BB, CCC 다: 뒤의
-- 대안이 더 길게 매치하더라도 첫 번째 대안이 이긴다.
WITH test_alt_three_way AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B','C']),
        (2, ARRAY['A','B','C']),
        (3, ARRAY['A','B','C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_three_way
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A | B B | C C C))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ((A | B | C)+): 한 번이 아니라 매 반복마다 세 대안의 순위가 매겨진다.  각
-- 행은 세 플래그를 모두 가진다.
WITH test_alt_three_way_loop AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B','C']),
        (2, ARRAY['A','B','C']),
        (3, ARRAY['A','B','C']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_three_way_loop
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A | B | C)+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- (A B | A C): 분기들이 접두사 A 를 공유하므로, 선택은 B 와 C 를 모두 가진 2
-- 행에서만 결정된다.  거기서는 첫 번째 대안이 이긴다.
WITH test_alt_shared_prefix AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B','C']),
        (3, ARRAY['C']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_shared_prefix
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A B | A C))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- (A B C | A B): 첫 번째 대안이 더 길고
-- 들어맞으므로, 길이와 작성 순서가 일치한다.
WITH test_alt_shared_prefix_long_first AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_alt_shared_prefix_long_first
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A B C | A B))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ------------------------------------------------------------
-- 7.2.3 연결: Lexical Order
-- ------------------------------------------------------------

-- ((A | B) (C | D)): 우선성 순서는 AC, AD, BC, BD 다
-- 1 행은 A 와 B 에 매치하고, 2 행은 C 와 D 에 매치한다
-- 선호되는 매치: A 다음 C (두 위치 모두 첫 번째 대안)
WITH test_concat_lex AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['C','D'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_concat_lex
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B) (C | D))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags),
        D AS 'D' = ANY(flags)
);

-- ((A | B) C): 첫 번째 대안(A)은 실패하고 두 번째 대안(B)은 성공한다
-- 역추적을 테스트한다: 1 행은 B 만 가지고, 2 행은 C 를 가진다
WITH test_concat_backtrack AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['C']),
        (3, ARRAY['A']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_concat_backtrack
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A | B) C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ------------------------------------------------------------
-- 7.2.4 수량화: 탐욕적/소극적, Lexical Order > 길이
-- ------------------------------------------------------------

-- V{2,4} 탐욕적: 더 긴 매치가 선호된다
WITH test_quant_greedy AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_greedy
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{2,4})
    DEFINE
        A AS 'A' = ANY(flags)
);

-- V{2,4}? 소극적: 더 짧은 매치가 선호된다
WITH test_quant_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['A']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{2,4}?)
    DEFINE
        A AS 'A' = ANY(flags)
);

-- ((A|B){1,2}) 탐욕적: Lexical Order > 길이
-- 표준 예제: 우선성 AA, AB, A, BA, BB, B
WITH test_quant_lex_greedy AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_lex_greedy
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A | B){1,2}))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ((A|B){1,2}?) 소극적: Lexical Order > 길이
-- 표준 예제: 우선성 A, AA, AB, B, BA, BB
-- 단일 A 가 B 로 시작하는 어떤 매치보다도 선호된다
WITH test_quant_lex_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_lex_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A | B){1,2}?))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 모든 행이 A 이면서 B 이기도 한 A+?  B: 멈추는 것과 계속하는 것이 매 단계에서
-- 둘 다 가능하므로 소극성이 실제로 시험대에 오른다.  중첩이 없으면 소극적
-- 경로는 살아있는 대안에 맞서 시험되지 않는다.
WITH test_quant_reluctant_contested AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['A','B']),
        (3, ARRAY['A','B']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_reluctant_contested
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 같은 행에 대한 A+ B: 탐욕적 매칭은 뒤에 B 를 하나 남기면서도 가능한 한 많이
-- 취한다.  위의 소극적 사례와 대조하라.
WITH test_quant_greedy_contested AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A','B']),
        (2, ARRAY['A','B']),
        (3, ARRAY['A','B']),
        (4, ARRAY['_'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_greedy_contested
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A+ B)+?  C: 외부 수량자가 소극적이므로 한 번의 반복 후 멈추고 3 행에서
-- 가능한 C 를 취한다.  3 행은 A 이기도 하여 두 번째 반복을 진행시킬 수도
-- 있었지만, 소극성이 이를 거절한다.
WITH test_quant_reluctant_outer AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A','C']),
        (4, ARRAY['B']),
        (5, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_reluctant_outer
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+ B)+? C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 같은 행에 대한 (A+ B)+ C: 외부의 탐욕이 두 번째 반복을 취해 대신 5 행의 C 에
-- 도달한다.  위의 소극적 외부와 대조하라.
WITH test_quant_greedy_outer AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A','C']),
        (4, ARRAY['B']),
        (5, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_greedy_outer
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+ B)+ C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- A{2}?  B: 정확한 경계는 선택의 여지를 남기지 않으므로 소극적 표시가 아무것도
-- 바꾸어서는 안 된다.  2-3 행의 중첩은 경계가 {0,2}?  나 {1,2}?로 낮아졌음을
-- 드러낼 것이다.
WITH test_quant_reluctant_exact AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['A','B']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_reluctant_exact
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{2}? B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- A{2} B: 대조를 위한, 같은 경계의 탐욕적 표기.
WITH test_quant_exact AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A','B']),
        (3, ARRAY['A','B']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_quant_exact
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{2} B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ------------------------------------------------------------
-- 7.2.6 앵커: WINDOW 절에서는 허용되지 않는다
-- 6.13 에 따르면 "the anchors (^ and $) are not permitted with row
-- pattern matching in windows"이다.  R020 준수: 이들은 계속 거부되어야 하며,
-- 나중에 채울 공백이 아니다.
-- ------------------------------------------------------------

-- ^ 앵커: 거부됨
SELECT count(*) OVER w FROM (SELECT 1 AS v) t
WINDOW w AS (ORDER BY v ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (^ A) DEFINE A AS TRUE);

-- $ 앵커: 거부됨
SELECT count(*) OVER w FROM (SELECT 1 AS v) t
WINDOW w AS (ORDER BY v ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A $) DEFINE A AS TRUE);

-- ------------------------------------------------------------
-- 7.2.8 빈 매치의 무한 반복
-- (Perl 하한 정지 규칙)
-- ------------------------------------------------------------
-- 표준은 수량자의 반복 흔적을 나열하여 이 규칙을 풀어낸다.  아래에서 A 는 행에
-- 매치한 반복이고 ()는 아무것도 매치하지 않은 반복이다.  빈 반복은 마지막
-- 반복으로서만, 또는 하한 미만의 위치에서만 허용된다.
--   (A?){0,3}: (), (A), (()), (A A), (A ()), (A A A), (A A ())
--   (A?){1,3}: 위와 같으나 () 제외 -- 하한을 충족하지 못한다
--   (A?){2,3}: (A A), (A ()), (() A), (() ()), (A A A), (A A ()),
--              (() A A), (() A ()) -- 위치 1 의 마지막이 아닌 빈 반복이 하한
--              2 를 채운다

-- (A??)*B: 표준 7.2.8 의 도입 예제
-- "matched against a sequence of rows for which the only feasible
--  matching is: B"
-- A??는 소극적이며 빈 매치를 선호한다.  *는 탐욕적이지만 Perl 규칙은 min(=0)이
-- 충족된 빈 매치 뒤에 멈춘다.  예상: 각 B 행이 단독으로 매치한다
-- (A??는 빈 매치, *는 정지, B 가 매치)
WITH test_empty_reluctant_star AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_empty_reluctant_star
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A??)* B)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A?){0,3}: min=0, nullable 한 내부.  A 는 결코 매치하지 않지만 A?는 빈
-- 매치를 내어 min=0 을 즉시 충족한다.
WITH test_728_min0 AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_min0
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A?){0,3})
    DEFINE
        A AS 'A' = ANY(flags)
);

-- (A?){1,3}: min=1, nullable 한 내부.  A 는 결코 매치하지 않는다; 하나의 빈
-- 반복이 min=1 을 충족한다.
WITH test_728_min1 AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_min1
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A?){1,3})
    DEFINE
        A AS 'A' = ANY(flags)
);

-- (A?){2,3}: min=2, nullable 한 내부.  두 개의 빈 반복 -- ( () () ) -- 이
-- 여기서 유효하다: 첫 번째는 하한 미만이므로 루프를 멈추지 않는다.
WITH test_728_min2 AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_min2
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A?){2,3})
    DEFINE
        A AS 'A' = ANY(flags)
);

-- (A?){2,3} 혼합: 일부 행은 A 에 매치하고 일부는 아니다
WITH test_728_min2_mixed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_min2_mixed
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A?){2,3})
    DEFINE
        A AS 'A' = ANY(flags)
);

-- (A? | B){3}: min 미만의 빈 반복이 하한을 채우며, 이는 뒤의 분기보다 순위가
-- 높아야 한다.  2 행은 B 만이므로 A?는 거기서 빈 매치를 유도한다; 그 유도를
-- 반복하면 남은 반복이 채워지고 매치는 1 행에서 끝난다.  대신 B 분기를
-- 취했다면 2-3 행을 소비했을 것이다.
WITH test_728_empty_fills_min AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A', 'B']),
        (2, ARRAY['B']),
        (3, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_empty_fills_min
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? | B){3})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- 같은 패턴을 풀어 쓴 것.  서로 다른 변수 이름을 사용해 위의 말린 형태로
-- 병합되지 않게 했지만, 둘은 일치해야 한다.
WITH test_728_empty_fills_min_unrolled AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A', 'B']),
        (2, ARRAY['B']),
        (3, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_empty_fills_min_unrolled
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? | B) (C? | D) (E? | F))
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'A' = ANY(flags),
        D AS 'B' = ANY(flags),
        E AS 'A' = ANY(flags),
        F AS 'B' = ANY(flags)
);

-- (A? B?){2,3}: 실제 매치가 있는 다중 요소 nullable 본체 본체 A?  B?는
-- nullable 하지만 (둘 다 선택적), A 와 B 는 실제로 행에 매치한다.
-- 실제(비어 있지 않은) 반복은 정상적으로 loop-back 한다; fast-forward 는
-- 병렬 이탈 경로로만 발동한다 (EXIT ONLY, 탐욕적/소극적 loop 없음).
-- 데이터: A, B 행이 번갈아 나타남 (6 행)
-- 탐욕적: 각 행은 자신의 시작 위치에서 가장 긴 매치를 얻는다.
WITH test_728_multi_body AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['A']),
        (4, ARRAY['B']),
        (5, ARRAY['A']),
        (6, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_multi_body
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? B?){2,3})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A? B?){2,3}: 순수하게 빈 본체 (A 나 B 에 아무것도 매치하지 않음).
WITH test_728_multi_empty AS (
    SELECT * FROM (VALUES
        (1, ARRAY['C']),
        (2, ARRAY['C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_multi_empty
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? B?){2,3})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A? B?){2,3}: 실제 반복과 빈 반복이 섞임
WITH test_728_multi_mixed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B']),
        (3, ARRAY['C']),
        (4, ARRAY['A']),
        (5, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_multi_mixed
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? B?){2,3})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);


-- 정지 규칙은 교대 본체도 지배한다.  A, B 에 대해 탐욕적 (A? | B)*는
-- 반복 1 에서 A 를 취한다; 반복 2 에서는 선호되는 분기 A?가 빈
-- 매치를 내므로 수량자가 멈추고 B 는 결코 2 행을 소비하지 않는다.
WITH test_empty_stop_alt_body AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_empty_stop_alt_body
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? | B)*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- min = max 이면 그룹 자체의 탐욕성은 아무것도 말해주지 않으므로, 빈 매치가
-- 선호되는지는 본체가 결정한다: {n}?는 {n}과 같아야 한다.  A?는 소비를
-- 선호하고 (두 형태 모두 두 행을 취한다); A??는 빈 매치를 선호한다
-- (둘 다 빈 매치를 낸다).
WITH test_fixed_quant_body_greed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       count(*) OVER g  AS greedy_body,      -- ((A?){2})
       count(*) OVER gr AS greedy_body_rel,  -- ((A?){2}?)
       count(*) OVER r  AS rel_body,         -- ((A??){2})
       count(*) OVER rr AS rel_body_rel      -- ((A??){2}?)
FROM test_fixed_quant_body_greed
WINDOW g  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
              AFTER MATCH SKIP PAST LAST ROW PATTERN (((A?){2}))
              DEFINE A AS 'A' = ANY(flags)),
       gr AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
              AFTER MATCH SKIP PAST LAST ROW PATTERN (((A?){2}?))
              DEFINE A AS 'A' = ANY(flags)),
       r  AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
              AFTER MATCH SKIP PAST LAST ROW PATTERN (((A??){2}))
              DEFINE A AS 'A' = ANY(flags)),
       rr AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
              AFTER MATCH SKIP PAST LAST ROW PATTERN (((A??){2}?))
              DEFINE A AS 'A' = ANY(flags));
-- (A* | B)*: A*는 선호되는 대안이며 3 행에서 빈 매치를 내는데, 이는 하한 정지
-- 규칙에 의해 루프를 끝낸다.  B 는 결코 시도되지 않으므로, 그것을 취하면 더
-- 길었을지라도 매치는 B 행에 못 미쳐 멈춘다.  Perl 도 동의한다: "aabb"에 대한
-- (a*|b)*는 "aa"에 매치한다.
WITH test_728_nullable_alt_first AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_nullable_alt_first
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A* | B)*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (B | A*)*: 같은 본체, 대안 순서를 바꿈.  B 가 선호되고 소비하므로 빈 반복이
-- 생기지 않고 루프는 B 행에 도달한다.
WITH test_728_nullable_alt_second AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_nullable_alt_second
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((B | A*)*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A+ | B)*: 첫 번째 대안은 nullable 하지 않으므로 빈 반복을 낼 수 없고 루프는
-- B 행에 도달한다.  (A* | B)*와 비교하라.
WITH test_728_nonnullable_alt_first AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_nonnullable_alt_first
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A+ | B)*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- (A? | B){2,3}: 상한이 여전히 더 많은 반복을 허용할 수 있어도 정지 규칙은
-- 하한에서 묶인다.  첫 번째와 두 번째 반복은 A?를 통해 빈 매치가 되고, 이는
-- min 에서 루프를 멈춘다; 그러면 C 가 1 행에서 실패하고 역추적은 확장하는 대신
-- 두 번째 반복을 B 로 대체하므로, 매치는 B, A, C = 1-3 행이 된다.  Perl 도
-- 동의한다: (?:a?|b){2,3}c 는 같은 방식으로 역추적한다.  빈 정지 이후에도 계속
-- 반복하는 엔진은 대신 더 짧은 empty-empty-B 유도를 통해 1-2 행을 반환한다.
WITH test_728_stop_binds_at_min AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A','C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_stop_binds_at_min
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? | B){2,3} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 같은 행에 대한 (A? | B){1,2} C: 하한이 첫 번째 반복으로 충족되므로, A?를
-- 통한 빈 첫 반복이 루프를 즉시 멈춘다; C 는 1 행에서 실패하고 역추적은 B 를
-- 취한 다음 A, C = 1-3 행을 취하는데, 이는 Perl 의 (?:a?|b){1,2}c 와 같다.
-- 이는 그룹의 END 에 처음 도달한 경우이며, 사이클 가드는 그 END 를 이전에 본
-- 적이 없음에도 이를 빈 것으로 인식해야 한다; 이를 놓치는 엔진은 빈 반복을
-- 유지하여 empty, B, C 를 통해 1-2 행을 반환한다.
WITH test_728_stop_first_iteration AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A','C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_stop_first_iteration
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? | B){1,2} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 하한이 0 인 같은 경우이며, 표준은 이를 1 과 같은 그룹으로 다룬다.
WITH test_728_stop_first_iteration_min0 AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A','C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_stop_first_iteration_min0
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? | B){0,2} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- SKIP PAST LAST ROW 아래에서의 같은 경우: 2 행과 3 행은 매치 안에 든다.
WITH test_728_stop_first_iteration_past AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A','C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_stop_first_iteration_past
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A? | B){1,2} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- (B?? | B*){0,2} C: 소극적인 첫 분기가 먼저 빈 매치가 되고, 이는 min 0 에서
-- 루프를 멈추어 C 가 1 행에서 실패한다.  역추적은 B??가 1 행을 취하게 하고, 두
-- 번째 반복은 빈 매치가 되어 멈추어 C 가 2 행에서 실패하므로, B??는 2 행도
-- 취하고 C 는 3 행에 매치한다: Perl 에서처럼 1-3 행이다.  빈 첫 반복을 놓치면
-- 대신 그 이후에도 루프가 다시 실행되어, 매치는 더 긴 1-4 행 (빈 매치, 그다음
-- 1-3 행에 걸친 B*, 그다음 C)이 되는데 -- 이는 7.2.8 이 배제하는 유도다.
WITH test_728_stop_first_iteration_reluctant AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B']),
        (3, ARRAY['B','C']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_stop_first_iteration_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((B?? | B*){0,2} C)
    DEFINE
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- (A?? | B*){0,2} C: 소극적인 빈 반복이 루프를 멈추고, 역추적은 1-2 행에 걸친
-- B*에 도달한 뒤, 두 번째 반복에서 A??가 3 행을 취하고 C 가 4 행에 매치한다:
-- Perl 에서처럼 1-4 행이다.  빈 첫 반복을 놓치면 대신 1-2 행을 반환한다.
WITH test_728_stop_first_iteration_mixed AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['B','C']),
        (3, ARRAY['A']),
        (4, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_stop_first_iteration_mixed
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A?? | B*){0,2} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- test_728_stop_binds_at_min 의 행에 대한 (A? | B){3} C: 정확한 경계에서는 두
-- 개의 빈 반복이 min 미만에 있으므로 루프는 계속되어야 한다; 세 번째가 B 를
-- 취하고 매치는 1-2 행이다.  그 테스트의 {2,3} 사례와 대조하라.
WITH test_728_exact_below_min AS (
    SELECT * FROM (VALUES
        (1, ARRAY['B']),
        (2, ARRAY['A','C']),
        (3, ARRAY['C'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_exact_below_min
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? | B){3} C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- (A? | B){2,}: 정지 규칙은 하한을 넘어선 곳에도 적용된다.
-- 두 번의 반복이 A 행을 소비하여 min=2 를 충족한다; 세 번째는
-- A?를 통해 빈 매치가 되어 어떤 B 도 취하기 전에 루프를 끝낸다.
WITH test_728_nullable_alt_min2 AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A']),
        (3, ARRAY['B']),
        (4, ARRAY['B'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_728_nullable_alt_min2
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A? | B){2,})
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ------------------------------------------------------------
-- 7.3 이론과 실무에서의 패턴 매칭
-- ------------------------------------------------------------

-- 표준의 예제: 특정 데이터에 대한 A? B+
-- 우선성 순서: (A)(BBB), (A)(BB), (A)(B), ()(BBB), ()(BB), ()(B) 1 행:
-- A 조건 (price>100)이 거짓이다 -> A 실패 역추적: 빈 A?, 그다음 1 행부터 B+
-- 예상: 1-3 행이 B 로 매치한다 (A?는 빈 매치를 취함)
WITH test_73_example AS (
    SELECT * FROM (VALUES
        (1, 60),
        (2, 70),
        (3, 40)
    ) AS t(id, price)
)
SELECT id, price,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_73_example
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A? B+)
    DEFINE
        A AS price > 100,
        B AS TRUE
);
