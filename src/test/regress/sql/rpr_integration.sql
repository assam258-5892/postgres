-- ============================================================
-- RPR 통합 테스트
-- 행 패턴 인식(RPR)에 대한 플래너 최적화 상호작용 테스트
-- ============================================================
--
-- 각 플래너 최적화가 RPR 윈도우를 올바르게 처리하는지 검증한다.  개별 최적화가
-- 다른 곳에서 테스트되더라도, 이 파일은 모든 플래너/RPR 상호작용에 대한 단일
-- 점검 지점을 제공한다.
--
-- 이 파일은 자신이 만든 것을 모두 drop하지만 한 가지 예외가 있다: A3는 뷰
-- rpr_ev_opt_mixed 를 남겨 두어, pg_upgrade 와 pg_dump 가 RPR 윈도우와 비RPR
-- 윈도우가 함께 직렬화된 경우를 검사하게 한다.
--
-- A. 플래너 최적화 보호 테스트
--    A1. 프레임 최적화 우회
--    A2. Run Condition 푸시다운 우회
--    A3. 윈도우 중복 제거 방지 (RPR 대 비RPR)
--    A4. 윈도우 중복 제거 방지 (같은 PATTERN, 다른 DEFINE 또는 SKIP)
--    A5. RPR 윈도우 주변의 미사용 출력 제거
--    A6. 역방향 전이(inverse transition) 우회
--    A7. 비용 추정의 RPR 인지
--    A8. 서브쿼리 평탄화 방지
--    A9. DEFINE 표현식 비전파
--    A10. RPR + LIMIT
--
-- B. 통합 시나리오 테스트
--    B1. RPR + CTE
--    B2. RPR + JOIN
--    B3. RPR + 집합 연산
--    B4. RPR + 준비된 문(prepared statement)
--    B5. RPR + 파티션된 테이블
--    B6. RPR + LATERAL
--    B7. RPR + 재귀 CTE
--    B8. RPR + 증분 정렬(Incremental Sort)
--    B9. RPR + DEFINE 안의 volatile 함수
--    B10. RPR + WHERE 안의 상관 서브쿼리
--    B11. RPR + DEFINE 전용 컬럼 가지치기(pruning)
--    B12. RPR + 상관된 내비게이션 오프셋
--    B13. RPR + DEFINE 전용 매개변수 캐싱
--    B14. RPR + 다중 윈도우 정의
--

CREATE TABLE rpr_integ (id INT, val INT);
INSERT INTO rpr_integ VALUES
    (1, 10), (2, 20), (3, 15), (4, 25), (5, 5),
    (6, 30), (7, 35), (8, 20), (9, 40), (10, 45);

-- ============================================================
-- A1. 프레임 최적화 우회
-- ============================================================
-- optimize_window_clauses() 가 RPR 윈도우에 프레임 최적화를
-- 적용하지 않는지 검증한다.  아래 두 질의는 모두 같은 입력
-- 프레임(ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)과
-- row_number() 를 사용하며, row_number() 의 prosupport는
-- SupportRequestOptimizeWindowClause 를 처리하여 프레임 재작성을 일으킨다.
-- 비RPR 기준 질의에서는 플래너가 프레임을 ROWS UNBOUNDED PRECEDING 으로
-- 재작성하지만, RPR의 경우 optimize_window_clauses() 안의 가드가
-- 재작성을 막아 프레임이 지정된 그대로 유지된다.  영향받는 함수:
-- row_number, rank, dense_rank, percent_rank, cume_dist, ntile.  이들은
-- 모두 프레임을 ROWS UNBOUNDED PRECEDING 으로 바꾸어, RPR이 요구하는
-- ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING을 깨뜨리게 된다.

-- 비RPR 기준: 플래너가 프레임을 ROWS UNBOUNDED PRECEDING으로 재작성한다.
EXPLAIN (COSTS OFF)
SELECT row_number() OVER w FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING);

-- RPR의 경우: 프레임이 지정된 그대로 유지된다.
EXPLAIN (COSTS OFF)
SELECT row_number() OVER w FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val));

-- ============================================================
-- A2. Run Condition 푸시다운 우회
-- ============================================================
-- find_window_run_conditions() 가 RPR 윈도우에서 단조(monotonic) 필터를 Run
-- Condition으로 밀어내리지 않는지 검증한다.  RPR의 매치 개수는 프레임에 대한
-- 단조 누적이 아니라 패턴 매칭으로 결정되므로, "cnt > 0" 같은 필터로 윈도우
-- 함수 평가를 일찍 멈출 수 없다.  RPR이 요구하는 프레임(ROWS BETWEEN CURRENT
-- ROW AND UNBOUNDED
-- FOLLOWING)에서는 윈도우 함수의 단조 방향이 어떤 비교 연산자가 푸시다운을
-- 허용하는지를 결정한다:
--   증가(INCREASING) (<=): row_number, rank, dense_rank, percent_rank,
--                    cume_dist, ntile
--   감소(DECREASING) (>):  count(*). 현재 행이 앞으로 나아갈수록
--                    (UNBOUNDED FOLLOWING에서 끝나는) 프레임이 줄어들므로
--                    개수도 줄어든다.
-- RPR 윈도우 함수의 결과는 단조가 아니라 매치에 의존하므로, 이 푸시다운은
-- 적용되지 않는다.

-- 비RPR 기준: 필터가 Run Condition으로 나타날 것으로 예상된다.
EXPLAIN (COSTS OFF)
SELECT * FROM (
    SELECT count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
) t WHERE cnt > 0;

-- RPR의 경우: 필터는 Run Condition이 아니라
-- WindowAgg 위의 Filter로 나타나야 한다.
EXPLAIN (COSTS OFF)
SELECT * FROM (
    SELECT count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) t WHERE cnt > 0;

-- RPR 질의가 매치 개수가 0 보다 큰 모든 행을 여전히
-- 반환하는지 검증하여, 필터가 패턴 매칭을 조기에 끊는
-- 것이 아니라 WindowAgg 위에서 평가됨을 확인한다.
SELECT * FROM (
    SELECT id, val, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) t WHERE cnt > 0;

-- ============================================================
-- A3. 윈도우 중복 제거 방지 (RPR 대 비RPR)
-- ============================================================
-- RPR 윈도우와 비RPR 윈도우가 같은 ORDER BY와 프레임 명세를 공유하는 경우에도
-- PostgreSQL 이 둘을 병합하지 않는지 검증한다.  RPR 패턴 매칭은 단순한 프레임
-- 기반 집계와 의미적으로 다른 결과를 만들어 내므로, 두 윈도우는 별개의
-- WindowAgg 노드로 남아 있어야 한다.  파서 수준 테스트에는 인라인 윈도우
-- 명세를 사용하는데, 파서의 중복 제거 경로는 인라인 윈도우에만 적용되기
-- 때문이다; 플래너의 프레임 최적화는 이름 붙은 윈도우도 병합할 수
-- 있다(뒤쪽에서 다룬다).

-- 비RPR 기준: 명세가 동일한 두 인라인 윈도우는 파서에 의해 하나의 WindowAgg
-- 노드로 중복 제거되며, 이는 비RPR 윈도우에 대해 중복 제거 경로가 작동함을
-- 확인해 준다.
EXPLAIN (COSTS OFF)
SELECT
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS cnt,
    sum(val)  OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS total
FROM rpr_integ;

-- 인라인 RPR 윈도우와 인라인 비RPR 윈도우는 같은 ORDER BY와 프레임을
-- 공유하지만 서로 다른 WindowAgg 노드로 남아 있어야 한다.
EXPLAIN (COSTS OFF)
SELECT
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS rpr_cnt,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS normal_cnt
FROM rpr_integ;

-- 두 윈도우가 행마다 서로 독립된 개수를 반환하는지
-- 검증하여, 하나의 WindowAgg 로 병합되지 않았음을 확인한다.
SELECT
    id, val,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS rpr_cnt,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS normal_cnt
FROM rpr_integ;

-- 결과 수준: 두 윈도우가 병합되었다면 fv_normal 과 fv_rpr 은 모든 행에서
-- 일치했을 것이다.  실제로는 그렇지 않으므로 윈도우는 분리된 채로 남았다.
SELECT id, val,
    first_value(id) OVER (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    ) AS fv_normal,
    first_value(id) OVER w1 AS fv_rpr
FROM (VALUES (1, 10), (2, 20), (3, 30), (4, 40)) AS t(id, val)
WINDOW w1 AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 10
);

-- 위의 두 윈도우는 같은 프레임에서 시작한다. 이 두 윈도우는 그렇지 않다:
-- 프레임 최적화가 둘 다 재작성해야만 수렴할 수 있는데, RPR 윈도우는 그
-- 최적화에서 건너뛰어지므로 여전히 병합되면 안 된다. 이 뷰는 일부러 drop하지
-- 않고 남겨 둔다: 트리 안에서 RPR 윈도우와 비RPR 윈도우를 함께 직렬화하는
-- 유일한 뷰이므로, pg_upgrade/pg_dump 가 그 라운드트립을 검사하는 데 필요하다.
CREATE VIEW rpr_ev_opt_mixed AS
SELECT
    row_number() OVER w_normal AS rn_normal,
    row_number() OVER w_rpr AS rn_rpr
FROM generate_series(1, 5) AS s(v)
WINDOW
    w_normal AS (ORDER BY v RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
    w_rpr AS (
        ORDER BY v
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS v > 1
    );

EXPLAIN (COSTS OFF) SELECT * FROM rpr_ev_opt_mixed;

-- ============================================================
-- A4. 윈도우 중복 제거 방지 (같은 PATTERN, 다른 DEFINE 또는 SKIP)
-- ============================================================
-- 인라인 윈도우 중복 제거가, 같은 PATTERN 구조를 공유하지만 행 패턴 공통
-- 구문의 다른 한 부분에서 차이가 나는 두 RPR 윈도우를 병합하지 않는지
-- 검증한다.  ORDER BY, 프레임, PATTERN이 일치하더라도, DEFINE이 다르면 행을
-- 다르게 분류하고 AFTER MATCH SKIP이 다르면 스캔을 다시 시작하는 지점이
-- 달라지므로, 어느 쪽이든 두 개의 분리된 WindowAgg 노드를 내야 한다.
-- transformWindowFuncCall() 은 RPCommonSyntax 노드 전체를 비교하는데, 이
-- 노드는 rpPattern 과 함께 rpDefs 와 rpSkipTo 도 싣고 있다; 아래 각 사례는
-- 그중 한 필드씩만 다룬다.  중복 제거는 인라인 윈도우에만 적용되므로 여기서는
-- 인라인 명세를 사용한다.

-- 기준: 구조적으로 동일한(같은 PARTITION BY, ORDER BY, 프레임, PATTERN,
-- DEFINE) 두 인라인 RPR 윈도우는 파서에 의해 하나의 WindowAgg 노드로 중복
-- 제거되며, 이는 DEFINE이 일치하는 RPR 윈도우에 대해 파서 수준의 중복 제거가
-- 작동함을 확인해 준다.
EXPLAIN (COSTS OFF)
SELECT
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS cnt,
    sum(val)  OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS total
FROM rpr_integ;

-- 같은 PATTERN이지만 DEFINE 조건이 반대인 두 인라인 RPR 윈도우는 분리된
-- WindowAgg 노드로 남아 있어야 한다.
EXPLAIN (COSTS OFF)
SELECT
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS cnt_up,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val < PREV(val)) AS cnt_down
FROM rpr_integ;

-- 두 윈도우가 행마다 서로 다른 개수를 반환하는지 검증하여, DEFINE 조건이 중복
-- 제거로 뭉개지지 않았음을 확인한다.
SELECT
    id, val,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS cnt_up,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val < PREV(val)) AS cnt_down
FROM rpr_integ;

-- AFTER MATCH SKIP 모드만 다르고 나머지는 모두 같은 두 인라인 RPR 윈도우도
-- 분리된 채로 남아 있어야 한다.  SKIP PAST LAST ROW는 매치 이후부터 다시
-- 시작하고, SKIP TO NEXT ROW는 한 행 안쪽에서 다시 시작하므로, 매치의 뒤쪽
-- 행들이 자기 자신의 매치를 새로 시작할 수 있다.
EXPLAIN (COSTS OFF)
SELECT
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS cnt_past,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP TO NEXT ROW
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS cnt_next
FROM rpr_integ;

-- 두 윈도우가 skip-past된 매치가 덮었던 행들에 대해 서로 다른 결과를 내는지
-- 검증하여, skip 모드가 중복 제거로 뭉개지지 않았음을 확인한다.
SELECT
    id, val,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS cnt_past,
    count(*) OVER (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP TO NEXT ROW
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)) AS cnt_next
FROM rpr_integ;

-- ============================================================
-- A5. RPR 윈도우 주변의 미사용 출력 제거
-- ============================================================
-- 바깥 질의는 행 개수만 세고 count(*) OVER w를 전혀 읽지
-- 않으므로, 윈도우 함수는 NULL로 대체되고 윈도우는 비활성
-- 상태가 되며 그 WindowAgg 는 제거되어 -- 스캔 위에 평범한
-- Aggregate만 남는다.  행 개수(따라서 count(*)도)는 그대로다.
EXPLAIN (COSTS OFF)
SELECT count(*) FROM (
    SELECT count(*) OVER w FROM rpr_integ
    WINDOW w AS (
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > PREV(val))
) t;

SELECT count(*) FROM (
    SELECT count(*) OVER w FROM rpr_integ
    WINDOW w AS (
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > PREV(val))
) t;

-- sum(cnt)가 윈도우 함수의 값을 읽으므로 이 컬럼은 제거할 수 없다.
EXPLAIN (COSTS OFF, VERBOSE)
SELECT count(*), sum(cnt) FROM (
    SELECT count(*) OVER w as cnt FROM rpr_integ
    WINDOW w AS (
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > PREV(val))
) t;

SELECT count(*), sum(cnt) FROM (
    SELECT count(*) OVER w as cnt FROM rpr_integ
    WINDOW w AS (
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > PREV(val))
) t;

-- 내비게이션이 없는 DEFINE: DEFINE A AS TRUE는 모든 행에 매치되므로, PREV/NEXT
-- 내비게이션이 없어도 PATTERN (A+)는 여전히 프레임을 (남은 파티션 전체로)
-- 축소한다.  sum(c)가 윈도우 값을 읽으므로 WindowAgg 는 유지된다; 이는 사소한
-- DEFINE도 여전히 프레임 축소를 이끌어 내어 예상된 개수를 낳는지를 검사한다.
EXPLAIN (COSTS OFF)
SELECT count(*), sum(c) FROM (
    SELECT count(*) OVER w AS c FROM rpr_integ
    WINDOW w AS (
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS TRUE)
) t;

SELECT count(*), sum(c) FROM (
    SELECT count(*) OVER w AS c FROM rpr_integ
    WINDOW w AS (
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS TRUE)
) t;

-- "val"은 바깥 질의가 전혀 읽지 않는 non-resjunk 서브쿼리 출력이므로,
-- remove_unused_subquery_outputs() 가 이를 NULL로 대체한다; WindowAgg Output
-- 줄의 "NULL::integer"가 이를 보여 준다.  DEFINE은 이 출력 항목이 아니라 그
-- 아래의 rpr_integ.val을 읽는데, 이는 build_base_rel_tlists() 와
-- make_window_input_target() 이 WindowAgg 의 입력으로 실어 나르며, Sort와 Seq
-- Scan의 Output 줄이 이를 보여 준다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT count(*) FROM (
    SELECT val, count(*) OVER w AS c FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) t WHERE c > 0;

SELECT count(*) FROM (
    SELECT val, count(*) OVER w AS c FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) t WHERE c > 0;

-- 같은 컬럼이 최상위 수준에서도 살아남아야 하는데, 여기서는
-- remove_unused_subquery_outputs() 가 아예 실행되지 않는다:
-- "val"은 DEFINE에서만 참조되므로, build_base_rel_tlists() 가
-- 이를 필요하다고 표시하는 것만이 join 트리 위로 이를 실어
-- 올리는 유일한 경로이고, make_window_input_target() 이 그것을
-- 다시 요청한다.  이를 출력하지 않는 WindowAgg 아래의 Sort와
-- Seq Scan Output 줄에 있는 "val"이 그 단언(assertion)이다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val));

SELECT id, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val));

-- DEFINE 컬럼은 join 제거에서도 살아남아야 한다: build_base_rel_tlists() 는
-- DEFINE이 읽는 u.uval을 relation 0 에서 필요하다고 표시하므로, LEFT JOIN은
-- 유지되고 DEFINE의 Var는 계획 안에서 여전히 어떤 relation을 가리킨다.
CREATE TABLE rpr_integ_u (id INT PRIMARY KEY, uval INT);
INSERT INTO rpr_integ_u SELECT i, i * 10 FROM generate_series(1, 5) i;

EXPLAIN (COSTS OFF)
SELECT id, c FROM (
    SELECT t.id AS id, u.uval AS uv, count(*) OVER w AS c
    FROM rpr_integ t LEFT JOIN rpr_integ_u u ON t.id = u.id
    WINDOW w AS (ORDER BY t.id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS uval > PREV(uval))
) s ORDER BY id;

SELECT id, c FROM (
    SELECT t.id AS id, u.uval AS uv, count(*) OVER w AS c
    FROM rpr_integ t LEFT JOIN rpr_integ_u u ON t.id = u.id
    WINDOW w AS (ORDER BY t.id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS uval > PREV(uval))
) s ORDER BY id;

-- 평탄화된 서브쿼리 출력이 외부 join에 의해 nullable해지면, 그것은 Var가
-- 아니라 PlaceHolderVar 로 DEFINE절에 도달한다.  build_base_rel_tlists() 가
-- 이를 필요하다고 표시하고 make_window_input_target() 이 이를
-- 요청하므로, 그것은 WindowAgg 의 입력에 도달한다: 뒤쪽의
-- "(COALESCE(rpr_integ_u.uval, 0))"이 그 단언이다.  coalesce() 는
-- 의도적인 것이며 단순화되어 사라지면 안 된다: "uval + 1" 같은
-- strict 표현식은 join이 매치를 찾지 못하면 그 자체로 NULL이 되므로,
-- pullup이 이를 감싸지 않고 이 사례는 평범한 Var로 퇴화해 버린다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT t.id, count(*) OVER w AS c
FROM rpr_integ t
     LEFT JOIN (SELECT id AS uid, coalesce(uval, 0) AS uv1 FROM rpr_integ_u) s
     ON t.id = s.uid
WINDOW w AS (ORDER BY t.id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS uv1 > PREV(uv1));

SELECT t.id, count(*) OVER w AS c
FROM rpr_integ t
     LEFT JOIN (SELECT id AS uid, coalesce(uval, 0) AS uv1 FROM rpr_integ_u) s
     ON t.id = s.uid
WINDOW w AS (ORDER BY t.id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS uv1 > PREV(uv1));

-- 같은 모양이지만 윈도우가 죽은 경우: count(*) OVER w를 아무도 읽지 않으므로
-- 그 항목이 사라지고 w도 함께 사라진다.  grouping_planner() 는 서브쿼리가
-- 계획될 때 w의 DEFINE절을 비우므로, u.uval을 필요하다고 표시하는 것이 없고
-- "uv"도 읽히지 않는다.  그 결과 rpr_integ_u 는 참조되지 않게 되어, join
-- 제거가 LEFT JOIN까지 가져가고 스캔만 남는다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id FROM (
    SELECT t.id AS id, u.uval AS uv, count(*) OVER w AS c
    FROM rpr_integ t LEFT JOIN rpr_integ_u u ON t.id = u.id
    WINDOW w AS (ORDER BY t.id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS uval > PREV(uval))
) s;

SELECT id FROM (
    SELECT t.id AS id, u.uval AS uv, count(*) OVER w AS c
    FROM rpr_integ t LEFT JOIN rpr_integ_u u ON t.id = u.id
    WINDOW w AS (ORDER BY t.id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS uval > PREV(uval))
) s ORDER BY id;

-- 하나의 서브쿼리 안에 살아 있는 윈도우와 죽은 RPR 윈도우가 함께 있는 경우.
-- 죽은 쪽의 DEFINE절을 비우는 것이 windowClause 안의 위치인 winref를
-- 흩트리거나 살아 있는 윈도우의 결과를 건드려서는 안 된다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id, c1 FROM (
    SELECT t.id AS id, u.uval AS uv,
           count(*) OVER w1 AS c1, count(*) OVER w2 AS c2
    FROM rpr_integ t LEFT JOIN rpr_integ_u u ON t.id = u.id
    WINDOW w1 AS (ORDER BY t.id),
           w2 AS (ORDER BY t.id
               ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A B+)
               DEFINE B AS uval > PREV(uval))
) s;

SELECT id, c1 FROM (
    SELECT t.id AS id, u.uval AS uv,
           count(*) OVER w1 AS c1, count(*) OVER w2 AS c2
    FROM rpr_integ t LEFT JOIN rpr_integ_u u ON t.id = u.id
    WINDOW w1 AS (ORDER BY t.id),
           w2 AS (ORDER BY t.id
               ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A B+)
               DEFINE B AS uval > PREV(uval))
) s ORDER BY id;

DROP TABLE rpr_integ_u;

-- w2는 선언되어 있지만 어떤 윈도우 함수도 이를 참조하지 않으므로,
-- select_active_windows() 는 서브쿼리가 계획될 때 이를 버리고
-- grouping_planner() 는 그 DEFINE절을 비운다.  읽히지 않는 val의 출력은 null
-- Const가 되고, rpr_integ.val을 요청하는 것이 더는 남지 않으므로 WindowAgg
-- 아래의 Sort와 Seq Scan도 이를 실어 나르지 않는다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT c FROM (
    SELECT count(*) OVER w1 AS c, val
    FROM rpr_integ
    WINDOW w1 AS (ORDER BY id),
           w2 AS (ORDER BY id
               ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A B+)
               DEFINE B AS val > PREV(val))
) t;

-- 여기서는 w2에 윈도우 함수가 있지만 바깥 질의가 이를 읽지 않으므로,
-- remove_unused_subquery_outputs() 가 그 항목을 null Const로
-- 대체하고, 서브쿼리가 계획될 때 w2는 비활성 상태가 된다.  그
-- DEFINE절은 위와 같이 비워지므로 rpr_integ.val은 WindowAgg
-- 아래로 실려 가지 않는다.  WindowAgg 의 Output 줄에 있는 두
-- null Const와, Sort 및 Seq Scan에서 빠진 "val"이 그 단언이다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT c FROM (
    SELECT count(*) OVER w1 AS c, count(*) OVER w2 AS unread, val
    FROM rpr_integ
    WINDOW w1 AS (ORDER BY id),
           w2 AS (ORDER BY id
               ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A B+)
               DEFINE B AS val > PREV(val))
) t;

-- 같은 모양이지만 윈도우 함수가 한 단계 안쪽, 표현식 안에 있는 경우.  전체
-- 항목이 null Const로 대체되면서 안에 중첩된 윈도우 함수도 함께 사라지므로,
-- w2는 위와 마찬가지로 비활성 상태가 된다. 이 계획이 위의 계획과 일치하는 것이
-- 그 단언이다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT c FROM (
    SELECT count(*) OVER w1 AS c, (count(*) OVER w2) + 1 AS unread, val
    FROM rpr_integ
    WINDOW w1 AS (ORDER BY id),
           w2 AS (ORDER BY id
               ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A B+)
               DEFINE B AS val > PREV(val))
) t;

SELECT c FROM (
    SELECT count(*) OVER w1 AS c, (count(*) OVER w2) + 1 AS unread, val
    FROM rpr_integ
    WINDOW w1 AS (ORDER BY id),
           w2 AS (ORDER BY id
               ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A B+)
               DEFINE B AS val > PREV(val))
) t;

CREATE TABLE rpr_integ_two (id int, v1 int, v2 int);
INSERT INTO rpr_integ_two SELECT i, i * 10, i * 100 FROM generate_series(1, 5) i;

-- 윈도우가 활성 상태인지는 행 패턴 인식 전체가 아니라 윈도우절 단위로
-- 결정된다: w3의 함수가 사라지면 w3의 DEFINE만 이름으로 가리키는 컬럼도 함께
-- 사라지지만, w2의 DEFINE이 읽는 컬럼은 여전히 WindowAgg 의 입력으로 실려
-- 간다.  읽히지 않는 두 출력 v1과 v2는 모두 null Const가 된다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT c2 FROM (
    SELECT count(*) OVER w2 AS c2, count(*) OVER w3 AS c3, v1, v2
    FROM rpr_integ_two
    WINDOW w2 AS (ORDER BY id
              ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
              PATTERN (A B+)
              DEFINE B AS v1 > PREV(v1)),
           w3 AS (ORDER BY id
              ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
              PATTERN (A B+)
              DEFINE B AS v2 > PREV(v2))
) t;

-- 윈도우 함수 항목은 상위 질의가 읽는다는 이유가 아닌 다른
-- 이유로도 -- 여기서는 서브쿼리 자신의 ORDER BY -- 유지될 수
-- 있으며, 그러면 그 윈도우는 활성 상태를 유지하고 DEFINE절도
-- 유지되므로, 그 절이 읽는 컬럼은 여전히 WindowAgg 의 입력으로
-- 실려 가는 반면 읽히지 않는 출력 v1은 null Const가 된다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT c FROM (
    SELECT count(*) OVER w1 AS c, count(*) OVER w2 AS ord, v1
    FROM rpr_integ_two
    WINDOW w1 AS (ORDER BY id),
           w2 AS (ORDER BY id
              ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
              PATTERN (A B+)
              DEFINE B AS v1 > PREV(v1))
    ORDER BY 2
) t;

DROP TABLE rpr_integ_two;

-- DEFINE 안의 전체 행 Var는 허용되지 않는다
SELECT sum(c) FROM (
    SELECT val, count(*) OVER w AS c FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS rpr_integ IS NOT NULL)
) t;

-- 그런데도 그것은 직접 쓰이지 않고도 DEFINE절에 도달할 수 있다: 서브쿼리를
-- pull-up하면 그 서브쿼리의 출력 표현식들이 defineClause 에 대입되는데, 그중
-- 하나가 전체 행 Var(속성 번호 0)일 수 있다.  윈도우 입력 타겟은 이를 다른
-- DEFINE 컬럼과 똑같이 받아들이므로, 패턴 매칭은 서브쿼리가 무엇을
-- 프로젝션하든 관계없이 행 전체를 본다.  따라서 사용되지 않는 스칼라 출력
-- "val"은 자유롭게 NULL로 대체될 수 있는 반면(아무도 읽지 않으므로), c는
-- sum(c)가 읽으므로 유지된다; 매치 결과는 그대로다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT sum(c) FROM (
    SELECT val, count(*) OVER w AS c
    FROM (SELECT r, r.id AS id, r.val AS val FROM rpr_integ r) s
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS r IS NOT NULL)
) t;

SELECT sum(c) FROM (
    SELECT val, count(*) OVER w AS c
    FROM (SELECT r, r.id AS id, r.val AS val FROM rpr_integ r) s
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS r IS NOT NULL)
) t;

-- 윈도우 함수는 sub-select의 test 표현식 안에도 놓일 수 있는데, 이
-- 경우 그것은 sub-select가 아니라 현재 질의 수준에 속한다.  바깥 질의가
-- m으로 필터링하므로 이 항목은 유지되고, test 표현식 안의 윈도우 함수가
-- w를 활성 상태로 유지한다: DEFINE절은 남아 있고, rpr_integ.val은
-- WindowAgg 의 입력으로 실려 가는 반면 읽히지 않는 출력 val은 null
-- Const가 된다.  만약 w가 비활성으로 취급되었다면 그 DEFINE절은
-- 비워졌을 것이고, B는 모든 행에 매치되어 길이 2 인 매치를 시작하는
-- 행이 하나도 없었을 것이다; 실제로는 1 행과 3 행이 그렇게 한다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT count(*) FROM (
    SELECT id, val, (count(*) OVER w) IN (SELECT 2) AS m
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
    OFFSET 0
) t WHERE m;

SELECT count(*) FROM (
    SELECT id, val, (count(*) OVER w) IN (SELECT 2) AS m
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
    OFFSET 0
) t WHERE m;

-- ============================================================
-- A6. 역방향 전이(inverse transition) 우회
-- ============================================================
-- RPR 윈도우가 이동 집계(moving aggregate, 역방향 전이) 최적화를 사용하지
-- 않는지 검증한다.  이동 집계는 들어오는 행을 더하고 나가는 행을 빼는 방식으로
-- 상태를 유지하지만, RPR의 축소된 프레임은 슬라이딩 윈도우가 아니다; 프레임에
-- 포함되는 행의 집합은 패턴 매칭으로 결정되며 이전 프레임으로부터 증분적으로
-- 유도할 수 없다.

-- sum() 은 평범한 윈도우에서는 역방향 전이 대상이 되지만, RPR의 축소된
-- 프레임에서는 rpr_is_defined() 가 peraggstate->restart를 강제하므로 집계가
-- 처음부터 다시 계산된다.  아래의 로깅 집계는 이 우회를 직접 단언한다.
SELECT id, val,
    sum(val) OVER w AS pattern_sum
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
ORDER BY id;

-- 사용자 정의 집계는 자신의 전이 함수가 어떻게 호출되는지 기록한다: msfunc는
-- 순방향 전이에 대해 '+'를 덧붙이고, minvfunc는 역방향 전이에 대해 '-'를
-- 덧붙인다.  RPR의 축소된 프레임에서는 '+'만 나타나며, 이는 역방향 전이 경로가
-- 사용되지 않음을 확인해 주고, 기록된 값은 각 프레임이 집계에 어떤 행을
-- 공급하는지 보여 준다.
CREATE FUNCTION rpr_logging_sfunc(text, anyelement) RETURNS text AS
$$ SELECT COALESCE($1, '') || '*' || quote_nullable($2) $$ LANGUAGE SQL IMMUTABLE;
CREATE FUNCTION rpr_logging_msfunc(text, anyelement) RETURNS text AS
$$ SELECT COALESCE($1, '') || '+' || quote_nullable($2) $$ LANGUAGE SQL IMMUTABLE;
CREATE FUNCTION rpr_logging_minvfunc(text, anyelement) RETURNS text AS
$$ SELECT $1 || '-' || quote_nullable($2) $$ LANGUAGE SQL IMMUTABLE;
CREATE AGGREGATE rpr_logging_agg (anyelement)
(
    stype = text,
    sfunc = rpr_logging_sfunc,
    mstype = text,
    msfunc = rpr_logging_msfunc,
    minvfunc = rpr_logging_minvfunc
);

-- 매치 1 은 id1..id3(v = NULL,'a','b')이고 매치 2 는 id4..id6
-- (v = NULL,'c','d')다; k가 늘어나는 동안 B가 매치를 확장한다.  모든 프레임은
-- '+'만 보여 주고('-'는 없음), 두 매치는 경계를 넘어 상태를 공유하지 않는다.
SELECT id, v,
    rpr_logging_agg(v) OVER w AS logged
FROM (VALUES
    (1, 1, NULL),
    (2, 3, 'a'),
    (3, 5, 'b'),
    (4, 2, NULL),
    (5, 4, 'c'),
    (6, 6, 'd')
) AS t(id, k, v)
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS k > PREV(k))
ORDER BY id;

DROP AGGREGATE rpr_logging_agg(anyelement);
DROP FUNCTION rpr_logging_sfunc(text, anyelement);
DROP FUNCTION rpr_logging_msfunc(text, anyelement);
DROP FUNCTION rpr_logging_minvfunc(text, anyelement);

-- ============================================================
-- A7. 비용 추정의 RPR 인지
-- ============================================================
-- cost_windowagg() 는 DEFINE 표현식 평가 비용을 반영해야 한다.  RPR WindowAgg
-- 비용이 비RPR WindowAgg 비용보다 큰지 검증한다.

CREATE FUNCTION rpr_get_windowagg_cost(query text) RETURNS numeric AS $$
DECLARE
    plan json;
    cost numeric;
BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) ' || query INTO plan;
    cost := (plan->0->'Plan'->>'Total Cost')::numeric;
    RETURN cost;
END;
$$ LANGUAGE plpgsql;

SELECT rpr_get_windowagg_cost(
    'SELECT count(*) OVER w FROM rpr_integ
     WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                  PATTERN (A B+ C+) DEFINE B AS val > PREV(val), C AS val < PREV(val))')
    >
    rpr_get_windowagg_cost(
    'SELECT count(*) OVER w FROM rpr_integ
     WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)')
    AS rpr_cost_is_higher;

DROP FUNCTION rpr_get_windowagg_cost(text);

-- ============================================================
-- A8. 서브쿼리 평탄화 방지
-- ============================================================
-- RPR 윈도우를 담은 서브쿼리가 바깥 질의로 평탄화되지 않는지 검증한다.
-- is_simple_subquery() 는 이미 윈도우 함수를 가진 서브쿼리 전반에 대해
-- pullup을 막고 있다; 이 테스트는 그 규칙이 RPR 윈도우에도 계속 적용되는지
-- 확인하며, 따라서 EXPLAIN은 여전히 RPR WindowAgg 위에 Subquery Scan을 보여
-- 주어야 한다.

EXPLAIN (COSTS OFF)
SELECT * FROM (
    SELECT id, val, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) sub
WHERE cnt > 0;

-- ============================================================
-- A9. DEFINE 표현식 비전파
-- ============================================================
-- DEFINE 표현식이 상위 WindowAgg 노드 어디의 targetlist로도 전파되지
-- 않는지 검증한다.  DEFINE이 소비하는 컬럼 참조만 윈도우 입력
-- 타겟에 추가되며, 전체 DEFINE 표현식은 그것을 소유한 RPR WindowAgg
-- 안에서만 의미가 있다.  따라서 EXPLAIN VERBOSE는 바깥쪽 WindowAgg 의
-- targetlist가 깨끗하고 DEFINE에서 파생된 표현식이 새어 들어오지
-- 않음을 보여 주어야 한다.  DEFINE이 읽는 컬럼("val")은 RPR WindowAgg
-- 및 그 아래에서만 나타나고, 바깥쪽 WindowAgg 에는 나타나지 않는다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT
    count(*) OVER w_rpr AS rpr_cnt,
    count(*) OVER w_normal AS normal_cnt
FROM rpr_integ
WINDOW
    w_rpr AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)),
    w_normal AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING);

SELECT
    count(*) OVER w_rpr AS rpr_cnt,
    count(*) OVER w_normal AS normal_cnt
FROM rpr_integ
WINDOW
    w_rpr AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val)),
    w_normal AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
ORDER BY rpr_cnt DESC, normal_cnt DESC;

-- ============================================================
-- A10. RPR + LIMIT
-- ============================================================
-- LIMIT은 RPR 패턴 매칭을 방해해서는 안 된다.  Limit 노드는 WindowAgg 위에
-- 있어야 패턴 매칭이 먼저 전체 파티션에 대해 실행될 수 있다; 그 결과는 LIMIT을
-- 걸지 않은 출력의 앞부분이 된다.  Limit을 WindowAgg 아래로 밀어내리면 매칭
-- 전에 입력이 잘려 나가 유효한 매치를 소리 없이 잃게 된다.
EXPLAIN (COSTS OFF)
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
LIMIT 5;

-- 기준: LIMIT 5 결과와 비교할, LIMIT을 걸지 않은 결과.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
ORDER BY id;

-- LIMIT 5 인 경우; 앞의 다섯 행이 위의 기준과 일치해야 한다.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
LIMIT 5;

-- ============================================================
-- B1. RPR + CTE
-- ============================================================
-- CTE 안에 내장된 RPR 윈도우가 직접 실행한
-- RPR 질의와 같게 동작하는지 검증한다:
--   (1) 한 번만 참조되는 CTE는 플래너가 인라인 처리하며, 직접 실행한 RPR
--       질의와 동일한 행별 결과를 낸다.
--   (2) 여러 번 참조되는 CTE는 materialize되어(계획에 CTE Scan이 나타남) 패턴
--       매칭이 한 번만 실행되며, 모든 참조가 같은 매치 결과를 본다.

-- 기준: 직접 실행한 RPR이 행별 기준 출력을 낸다.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
ORDER BY id;

-- 한 번만 참조되는 CTE: 계획에 "CTE rpr_result" 범위가 없으며, 이는 CTE가
-- 둘러싼 질의 안으로 인라인되었음을 보여 준다.
EXPLAIN (COSTS OFF)
WITH rpr_result AS (
    SELECT id, val, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
)
SELECT id, val, cnt FROM rpr_result ORDER BY id;

-- 결과는 기준과 행 단위로 일치해야 한다.
WITH rpr_result AS (
    SELECT id, val, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
)
SELECT id, val, cnt FROM rpr_result ORDER BY id;

-- 여러 번 참조되는 CTE(self-join): 계획에 "CTE rpr_result" 범위와 양쪽 모두에
-- CTE Scan 노드가 있으며, 이는 CTE가 materialize되어 패턴 매칭이 한 번만
-- 실행되었음을 보여 준다.
EXPLAIN (COSTS OFF)
WITH rpr_result AS (
    SELECT id, val, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
)
SELECT r1.id, r1.cnt
FROM rpr_result r1
JOIN rpr_result r2 ON r1.id = r2.id AND r1.cnt = r2.cnt
WHERE r1.cnt > 0
ORDER BY r1.id;

-- 결과: 두 참조 모두 같은 매치 개수를 보므로, self-join은 기준의 매치된 행을
-- 모두 보존한다.
WITH rpr_result AS (
    SELECT id, val, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
)
SELECT r1.id, r1.cnt
FROM rpr_result r1
JOIN rpr_result r2 ON r1.id = r2.id AND r1.cnt = r2.cnt
WHERE r1.cnt > 0
ORDER BY r1.id;

-- ============================================================
-- B2. RPR + JOIN
-- ============================================================
-- RPR 서브쿼리를 다른 relation과 join할 수 있는지 검증한다.  두 가지 측면을
-- 비RPR 기준과 대조하여 확인한다:
--   (1) 평탄화: 비RPR 서브쿼리는 플래너에 의해
--       pull-up된다(계획에 Subquery Scan이 없음); RPR 서브쿼리는
--       평탄화되지 않은 채로 유지된다(WindowAgg 위에 Subquery Scan).
--   (2) join의 정확성: join은 각 RPR 매치 행을 같은 키를 가진 차원
--       테이블(dimension table) 행과 맞춘다.

CREATE TABLE rpr_integ2 (id INT, label TEXT);
INSERT INTO rpr_integ2 VALUES
    (1, 'a'), (2, 'b'), (3, 'c'), (4, 'd'), (5, 'e'),
    (6, 'f'), (7, 'g'), (8, 'h'), (9, 'i'), (10, 'j');

-- 기준: 비RPR 서브쿼리는 플래너에 의해 평탄화된다.  Subquery Scan 노드가
-- 나타나지 않으며, 안쪽 SELECT는 바깥쪽 join으로 합쳐진다.
EXPLAIN (COSTS OFF)
SELECT r.id, r.val, j.label
FROM (SELECT id, val FROM rpr_integ) r
JOIN rpr_integ2 j ON r.id = j.id
ORDER BY r.id;

-- RPR 서브쿼리 JOIN: Subquery Scan이 WindowAgg 위에 그대로 유지되며, 이는 RPR
-- 서브쿼리가 평탄화되지 않았음을 확인해 준다.
EXPLAIN (COSTS OFF)
SELECT r.id, r.cnt, j.label
FROM (
    SELECT id, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) r
JOIN rpr_integ2 j ON r.id = j.id
WHERE r.cnt > 0
ORDER BY r.id;

-- 결과: 매치된 RPR 행이 id를 기준으로 차원 테이블 행과 맞춰지며, 이는 join이
-- 행별 매치 개수를 해당 레이블과 올바르게 짝짓는다는 것을 보여 준다.
SELECT r.id, r.cnt, j.label
FROM (
    SELECT id, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) r
JOIN rpr_integ2 j ON r.id = j.id
WHERE r.cnt > 0
ORDER BY r.id;

-- ============================================================
-- B3. RPR + 집합 연산
-- ============================================================
-- RPR 결과가 UNION ALL 아래에서 비RPR 결과와 올바르게 결합되는지 검증한다.
-- 계획은 두 개의 독립된 자식 계획을 가진 Append 노드를 보여 주어야 한다:
-- Pattern/DEFINE이 활성인 RPR 분기와, 평범한 WindowAgg 를 가진 비RPR 분기.  각
-- 자식은 각자 기본 relation을 스캔하여 자신의 행을 union된 출력에 보탠다.

-- 계획: 두 개의 독립된 자식을 가진 Append.  RPR 분기는 Pattern/Nav Mark
-- Lookback을 싣고 있는 WindowAgg 를 가지고, 비RPR 분기는 패턴 메타데이터가
-- 없는 평범한 WindowAgg 를 가진다.
EXPLAIN (COSTS OFF)
SELECT id, cnt, 'rpr' AS source FROM (
    SELECT id, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) t WHERE cnt > 0
UNION ALL
SELECT id, count(*) OVER (ORDER BY id) AS cnt, 'normal' AS source
FROM rpr_integ
ORDER BY source, id;

-- 결과: 두 분기의 행이 모두 union된 출력에 들어 있다.  RPR 분기는 매치된 행만
-- 내보내고(cnt > 0), 비RPR 분기는 자신의 개수 값과 함께 모든 행을 내보낸다.
SELECT id, cnt, 'rpr' AS source FROM (
    SELECT id, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) t WHERE cnt > 0
UNION ALL
SELECT id, count(*) OVER (ORDER BY id) AS cnt, 'normal' AS source
FROM rpr_integ
ORDER BY source, id;

-- ============================================================
-- B4. RPR + 준비된 문(prepared statement)
-- ============================================================
-- RPR의 내비게이션 오프셋(PREV(val, $1))으로 들어가는 매개변수로 plancache의
-- 두 모드를 모두 실행해 봄으로써, RPR 질의가 prepared statement 경로에서도
-- 제대로 동작하는지 검증한다. 이 매개변수는
-- RPR 특유의 plancache 차이를 드러낸다:
--   - custom plan: "Nav Mark Lookback"이 계획 시점에 리터럴 매개변수 값으로
--     해소된다(예: "Nav Mark Lookback: 1").
--   - generic plan: "Nav Mark Lookback"이 실행 시점으로 미뤄지며 계획에는
--     "Nav Mark Lookback: runtime"으로 나타난다.
-- 결과는 두 모드 모두에서 동일해야 한다.

-- prepared statement를 등록한다; DEFINE은 PREV(val, $1)을 사용하므로
-- 매개변수는 RPR의 내비게이션 기구에 도달한다.
PREPARE rpr_prev(int) AS
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val, $1))
ORDER BY id;

-- Custom plan: Nav Mark Lookback이 리터럴 1 로 해소된다.
SET plan_cache_mode = force_custom_plan;
EXPLAIN (COSTS OFF) EXECUTE rpr_prev(1);
EXECUTE rpr_prev(1);

-- Generic plan: Nav Mark Lookback이 실행 시점으로 미뤄지며 계획에는
-- "runtime"으로 나타난다.  결과는 custom plan의 결과와 정확히 일치해야 한다.
SET plan_cache_mode = force_generic_plan;
EXPLAIN (COSTS OFF) EXECUTE rpr_prev(1);
EXECUTE rpr_prev(1);

-- generic plan에서의 음수 runtime 내비게이션 오프셋: 초기화는 이를 실행
-- 시점으로 미루고("runtime"), 스캔별 오프셋 해소 단계가 이를 거부한다.
EXECUTE rpr_prev(-1);

RESET plan_cache_mode;
DEALLOCATE rpr_prev;

-- ============================================================
-- B5. RPR + 파티션된 테이블
-- ============================================================
-- 소스 relation이 파티션되어 있을 때도 RPR 패턴 매칭이 올바르게 동작하는지
-- 검증한다.  플래너는 RPR이 행들을 보기 전에 모든 파티션의 행을 하나의 정렬된
-- 스트림으로 모아야 하는데, 패턴 매칭은 전체 partition-by 그룹에 걸쳐
-- 순차적이며 각 테이블 파티션에서 독립적으로 수행될 수 없기 때문이다.

CREATE TABLE rpr_part (id INT, val INT) PARTITION BY RANGE (id);
CREATE TABLE rpr_part_1 PARTITION OF rpr_part FOR VALUES FROM (1) TO (6);
CREATE TABLE rpr_part_2 PARTITION OF rpr_part FOR VALUES FROM (6) TO (11);
INSERT INTO rpr_part SELECT id, val FROM rpr_integ;

-- 계획: 파티션 스캔들이 Append(또는 Merge Append)로 합쳐져 하나의 정렬된
-- 스트림으로 정렬된 뒤, 결합된 스트림 전체에 대해 RPR 패턴 매칭을 수행하는
-- 하나의 WindowAgg 로 공급된다.
EXPLAIN (COSTS OFF)
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_part
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
ORDER BY id;

-- 기준: 파티션되지 않은 rpr_integ 에 대한 같은 질의가 행별 기준 출력을 낸다.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
ORDER BY id;

-- 파티션된 테이블에 대한 결과는 기준과 행 단위로 일치해야 한다.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_part
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
ORDER BY id;

DROP TABLE rpr_part;

-- ============================================================
-- B6. RPR + LATERAL
-- ============================================================
-- LATERAL 서브쿼리 안의 RPR.  바깥 질의로부터의 수식된(qualified) 컬럼
-- 참조는 DEFINE에서 아직 지원되지 않으므로, 이 테스트는 LATERAL이 상관
-- 필터(WHERE id <= o.id)를 제공하고 DEFINE은 지역 컬럼만 사용하는 기본
-- 사례를 다룬다.  계획은 바깥쪽 relation을 안쪽 서브쿼리 스캔으로 몰아가는
-- Nested Loop을 보여 주어야 하며, RPR WindowAgg 는 바깥쪽 행마다 다시
-- 실행되고 상관은 "id <= o.id"에 대한 스캔 수준 Filter로 드러난다.

-- 계획: RPR WindowAgg 가 안쪽 다리에 있는 Nested Loop이며, 필터링된 바깥쪽
-- 행들(o.id IN (5, 10))에 의해 구동된다.
EXPLAIN (COSTS OFF)
SELECT o.id AS outer_id, r.id, r.cnt
FROM rpr_integ o,
LATERAL (
    SELECT id, count(*) OVER w AS cnt
    FROM rpr_integ
    WHERE id <= o.id
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) r
WHERE r.cnt > 0 AND o.id IN (5, 10)
ORDER BY o.id, r.id;

-- 결과: 두 바깥쪽 id(5 와 10) 각각에 대해, LATERAL 서브쿼리는 제한된 입력에
-- 대한 RPR 매치 개수를 낸다.
SELECT o.id AS outer_id, r.id, r.cnt
FROM rpr_integ o,
LATERAL (
    SELECT id, count(*) OVER w AS cnt
    FROM rpr_integ
    WHERE id <= o.id
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
) r
WHERE r.cnt > 0 AND o.id IN (5, 10)
ORDER BY o.id, r.id;

-- lateral 바깥쪽 참조는 DEFINE 전용 컬럼과 varno 및 varattno를 공유할 수 있다:
-- 여기서는 o.b와 y가 각자의 질의 수준에서 모두 속성 번호 2 다.  바깥 질의가
-- lat을 읽지 않으므로, 대조군에서와 마찬가지로
-- remove_unused_subquery_outputs() 가 이를 NULL로 대체하는 반면, DEFINE 절이
-- rpr_lat_i 에서 읽는 y는 여전히 WindowAgg 의 입력으로 실려 간다.
CREATE TABLE rpr_lat_o (a int, b int);
CREATE TABLE rpr_lat_i (x int, y int);
INSERT INTO rpr_lat_o VALUES (1, 10);
INSERT INTO rpr_lat_i VALUES (1, 5), (2, 6);

-- 겹치는 모양: 바깥쪽 참조는 속성 번호 2 인 o.b다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT o.a, s.c
FROM rpr_lat_o o,
LATERAL (
    SELECT o.b AS lat, count(*) OVER w AS c
    FROM rpr_lat_i
    WINDOW w AS (ORDER BY x
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS y > 0)
) s;

SELECT o.a, s.c
FROM rpr_lat_o o,
LATERAL (
    SELECT o.b AS lat, count(*) OVER w AS c
    FROM rpr_lat_i
    WINDOW w AS (ORDER BY x
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS y > 0)
) s;

-- 대조군: 바깥쪽 참조는 속성 번호 1 인 o.a로, y와 혼동될 수 없다.  계획과
-- 개수는 위의 질의와 일치해야 한다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT o.a, s.c
FROM rpr_lat_o o,
LATERAL (
    SELECT o.a AS lat, count(*) OVER w AS c
    FROM rpr_lat_i
    WINDOW w AS (ORDER BY x
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS y > 0)
) s;

SELECT o.a, s.c
FROM rpr_lat_o o,
LATERAL (
    SELECT o.a AS lat, count(*) OVER w AS c
    FROM rpr_lat_i
    WINDOW w AS (ORDER BY x
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS y > 0)
) s;
DROP TABLE rpr_lat_o, rpr_lat_i;

-- ============================================================
-- B7. RPR + 재귀 CTE
-- ============================================================
-- RPR은 재귀 질의의 모든 다리에서 거부되며, 비재귀
-- 다리도 예외가 아니다(표준 인용은 parse_cte.c를 보라).

-- WITH RECURSIVE: 기저 다리(base leg)는 재귀 CTE 이름을 전혀 참조하지
-- 않는데도, 기저 다리 안의 RPR은 거부된다.
WITH RECURSIVE seq AS (
    SELECT id, val, count(*) OVER w AS cnt
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val))
    UNION ALL
    SELECT id + 100, val, cnt FROM seq WHERE id < 3
)
SELECT id, val, cnt FROM seq ORDER BY id;

-- CREATE RECURSIVE VIEW: makeRecursiveViewSelect() 에 의해
-- WITH RECURSIVE로 재작성되므로 같은 거부가 적용된다.  이것이
-- ISO/IEC 19075-5 6.17.5 가 그대로 인용하는 형태다.
CREATE RECURSIVE VIEW rpr_recv(id, val, cnt) AS
    SELECT id, val, count(*) OVER w
    FROM rpr_integ
    WINDOW w AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B+)
        DEFINE B AS val > PREV(val));

-- ============================================================
-- B8. RPR + 증분 정렬(Incremental Sort)
-- ============================================================
-- WindowAgg 에 대한 입력이 증분 정렬을 거쳐 도착할 때도 RPR 패턴 매칭이
-- 올바르게 동작하는지 검증한다.  (id) 위의 인덱스는 첫 번째 ORDER
-- BY 키에 대해 이미 정렬된 입력을 제공하므로, "ORDER BY id, val"은
-- 플래너가 두 번째 키에 대해서만 정렬하도록 Incremental Sort를 사용하게
-- 한다.  계획은 RPR WindowAgg 아래에 Incremental Sort를 보여 주어야
-- 하며, RPR은 평범한 Sort를 썼을 때와 같은 행별 매치 개수를 내야 한다.

CREATE INDEX rpr_integ_id_idx ON rpr_integ (id);
SET enable_seqscan = off;

-- 계획: Index Scan 위에 Incremental Sort가, 그 위에 RPR WindowAgg 가 있다.
-- Incremental Sort는 "Presorted Key: id"를 선언하며 각 id 그룹 안에서 val에
-- 대해서만 정렬한다.
EXPLAIN (COSTS OFF)
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id, val
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val));

-- 결과: 증분적으로 정렬된 스트림에 대한 RPR이 행별 매치 개수를 낸다.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id, val
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val))
ORDER BY id, val;

RESET enable_seqscan;
DROP INDEX rpr_integ_id_idx;

-- ============================================================
-- B9. RPR + DEFINE 안의 volatile 함수
-- ============================================================
-- DEFINE 안의 volatile 함수는 플래너에서 거부된다.  RPR의 NFA
-- 엔진 아래에서는 한 행의 DEFINE 술어가 몇 번 평가되는지를 질의가
-- 신뢰할 수 없으므로, volatile한 결과는 패턴 매칭을 비결정적으로
-- 만들 것이다. STABLE과 IMMUTABLE인 호출 대상은 받아들여진다.

-- 기준: STABLE인 to_char 와 IMMUTABLE인 length는 받아들여진다.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val)
                AND length('x') = 1
                AND to_char(date '2026-01-01', 'YYYY') = '2026')
ORDER BY id;

-- volatile인 random은 거부된다.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_integ
WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE B AS val > PREV(val) AND random() >= 0.0)
ORDER BY id;

-- ============================================================
-- B10. RPR + WHERE 안의 상관 서브쿼리
-- ============================================================
-- 상관 스칼라 서브쿼리 안에 놓인 RPR 윈도우가 바깥쪽 행마다 한
-- 번씩 실행되는지 검증한다.  DEFINE은 여전히 지역 컬럼만 참조한다
-- (바깥 질의로부터의 수식된 참조는 DEFINE에서 지원되지 않는다);
-- 상관은 서브쿼리의 WHERE절에 "i.id <= o.id"로 담겨 있다.
-- 계획은 바깥쪽 스캔에 붙은 SubPlan 을 보여 주어야 하며, RPR
-- WindowAgg 는 상관 술어를 담은 행별 스캔 필터에 의해 구동된다.

-- 계획: 바깥쪽 Seq Scan에 붙은 SubPlan; 안쪽 스캔은 "Filter: (id <= o.id)"를
-- 담고 있으며, 이는 상관이 바깥쪽 행마다 평가됨을 확인해 준다.
EXPLAIN (COSTS OFF)
SELECT o.id, o.val,
    (SELECT count(*) OVER w
     FROM rpr_integ i
     WHERE i.id <= o.id
     WINDOW w AS (ORDER BY id
         ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
         PATTERN (A B+)
         DEFINE B AS val > PREV(val))
     ORDER BY id
     LIMIT 1) AS first_cnt
FROM rpr_integ o
ORDER BY o.id;

-- 결과: 각 바깥쪽 행은 자신의 상관 RPR 서브쿼리로부터 first_cnt 를 받는다.
SELECT o.id, o.val,
    (SELECT count(*) OVER w
     FROM rpr_integ i
     WHERE i.id <= o.id
     WINDOW w AS (ORDER BY id
         ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
         PATTERN (A B+)
         DEFINE B AS val > PREV(val))
     ORDER BY id
     LIMIT 1) AS first_cnt
FROM rpr_integ o
ORDER BY o.id;

-- ============================================================
-- B11. RPR + DEFINE 전용 컬럼 가지치기(pruning)
-- ============================================================
-- DEFINE 전용 컬럼을 WindowAgg 의 입력으로 실어 나르는 것이
-- 관계없는 컬럼까지 살려 두지는 않는지 검증한다.  DEFINE은
-- a(rpr_over1)를 참조한다; c(rpr_over2)는 같은 속성 번호를
-- 가지지만 사용되지 않으므로 계획은 이를 제거해야 한다.
CREATE TABLE rpr_over1 (a int);
CREATE TABLE rpr_over2 (c int);
INSERT INTO rpr_over1 VALUES (1),(2),(3);
INSERT INTO rpr_over2 VALUES (1),(2),(3);

-- 계획: oc는 null Const가 되고 rpr_over2 의 스캔은 어떤 컬럼도 보태지 않는다;
-- DEFINE이 읽는 rpr_over1.a는 WindowAgg 의 입력에 도달한다.
EXPLAIN (VERBOSE, COSTS OFF)
SELECT cnt FROM (
  SELECT a AS oa, c AS oc, count(*) OVER w AS cnt
  FROM rpr_over1 CROSS JOIN rpr_over2
  WINDOW w AS (ORDER BY a ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (X+) DEFINE X AS a > 0)
) s;
DROP TABLE rpr_over1, rpr_over2;

-- DEFINE절은 그 안에 직접 쓰일 수는 없는데도 바깥쪽 질의 수준의 Var나
-- PlaceHolderVar 를 담게 될 수 있다: SQL 함수를 인라인하면 호출의 실제 인자가
-- 본문에 대입되면서 그것이 심어지는 수준이 올라가고, 서브쿼리 pull-up이 그것을
-- PlaceHolderVar 로 감쌀 수도 있다.  아래의 각 질의는 함수의 출력 x를 읽지
-- 않은 채로 두므로 그 항목은 NULL로 대체되며, 뒤이어 x를 읽는 같은 질의가
-- 나오는데 이 경우는 아무것도 가지치기하지 않는다; 두 개수는 일치해야 한다.
CREATE TABLE rpr_up (p int, x int);
INSERT INTO rpr_up SELECT g, 100 + g FROM generate_series(1, 6) g;
CREATE TABLE rpr_drv (k int);
INSERT INTO rpr_drv VALUES (2), (4);

-- 바깥쪽 Var이며, 가지치기된 컬럼을 읽지 않는 절인 경우:
CREATE FUNCTION rpr_up_f(th int) RETURNS TABLE (cnt bigint, x int)
LANGUAGE sql STABLE AS $$
  SELECT count(*) OVER w, x FROM rpr_up
  WINDOW w AS (ORDER BY p ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A+) DEFINE A AS p > th)
$$;
SELECT d.k, max(g.cnt) FROM rpr_drv d, LATERAL rpr_up_f(d.k) g
GROUP BY d.k ORDER BY 1;
SELECT d.k, max(g.cnt), max(g.x) FROM rpr_drv d, LATERAL rpr_up_f(d.k) g
GROUP BY d.k ORDER BY 1;

-- 같은 경우이지만 이번에는 그것을 읽는 절이다: 출력 항목
-- x는 여전히 NULL이 되는 반면, DEFINE절은 rpr_up.x를
-- 읽으며 이는 WindowAgg 의 입력으로 실려 간다.
CREATE FUNCTION rpr_up_h(th int) RETURNS TABLE (cnt bigint, x int)
LANGUAGE sql STABLE AS $$
  SELECT count(*) OVER w, x FROM rpr_up
  WINDOW w AS (ORDER BY p ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A+) DEFINE A AS x > th + 100)
$$;
SELECT d.k, max(g.cnt) FROM rpr_drv d, LATERAL rpr_up_h(d.k) g
GROUP BY d.k ORDER BY 1;
SELECT d.k, max(g.cnt), max(g.x) FROM rpr_drv d, LATERAL rpr_up_h(d.k) g
GROUP BY d.k ORDER BY 1;
-- 그리고 상수 인자를 쓰는 경우로, 바깥쪽 참조가 전혀 생기지 않는다:
SELECT max(cnt) FROM rpr_up_h(2);
SELECT max(cnt) FROM rpr_up_h(4);

-- 바깥쪽 PlaceHolderVar 이며, 인자를 공급하는 서브쿼리를 pull-up하면 Var
-- 자리에 이것이 대신 놓인다:
CREATE FUNCTION rpr_up_n(int) RETURNS TABLE (cnt bigint, x int)
LANGUAGE sql STABLE AS $$
  SELECT count(*) OVER w, x FROM rpr_up
  WINDOW w AS (ORDER BY p ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               INITIAL PATTERN (A+) DEFINE A AS PREV(p + $1) > 0)
$$;
SELECT s.k, max(g.cnt) FROM (SELECT 3 AS k FROM rpr_drv) s,
     LATERAL rpr_up_n(s.k) g GROUP BY s.k;
SELECT s.k, max(g.cnt), max(g.x) FROM (SELECT 3 AS k FROM rpr_drv) s,
     LATERAL rpr_up_n(s.k) g GROUP BY s.k;

DROP FUNCTION rpr_up_f(int), rpr_up_h(int), rpr_up_n(int);
DROP TABLE rpr_up, rpr_drv;

-- ============================================================
-- B12. RPR + 상관된 내비게이션 오프셋
-- ============================================================
-- 상관된 PARAM_EXEC 로 해소되는 행 패턴 내비게이션
-- 오프셋은(여기서는 rpr_srf_prev(g.n)의 SRF 인라인을 통해) executor
-- 초기화 시점에 고정되지 않고 재스캔마다 다시 해소되어야 한다.
-- 인라인된 WindowAgg 는 nestloop의 안쪽에 있어 바깥쪽 행마다 한
-- 번씩 재스캔되므로, 각 행은 자기 자신의 PREV(v, n) 오프셋을 본다;
-- 오프셋이 고정되어 있었다면 모든 행에 같은 값을 보고했을 것이다.
CREATE TABLE rpr_srf (v int);
INSERT INTO rpr_srf SELECT generate_series(1, 10);
CREATE FUNCTION rpr_srf_prev(k int) RETURNS SETOF bigint AS $$
  SELECT count(*) OVER w
  FROM rpr_srf
  WINDOW w AS (ORDER BY v ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A+) DEFINE A AS v > PREV(v, k))
$$ LANGUAGE sql STABLE;
-- 계획: 오프셋은 "runtime"으로 나타난다; WindowAgg 는 nestloop 안으로
-- 인라인되며 바깥쪽 행마다 재스캔된다.
EXPLAIN (COSTS OFF)
SELECT g.n, max(s) FROM (VALUES (1), (2), (3)) g(n), LATERAL rpr_srf_prev(g.n) s
GROUP BY g.n ORDER BY g.n;
-- 각 바깥쪽 행은 하나로 고정된 값이 아니라 자기 자신의 오프셋 (개수 9, 8,
-- 7)을 사용한다.
SELECT g.n, max(s) AS m FROM (VALUES (1), (2), (3)) g(n), LATERAL rpr_srf_prev(g.n) s
GROUP BY g.n ORDER BY g.n;

-- 순방향 FIRST 계열 오프셋(navFirstOffset / navFirstOffsetKind)도 마찬가지로
-- 스캔마다 다시 해소되어야 한다.  PATTERN (B A+)는 매치 시작을 B에 고정하여
-- A가 k행 앞의 FIRST(v, k)를 참조할 수 있게 하며, 바깥쪽 k 각각이 자기 자신의
-- 순방향 오프셋을 낸다.
CREATE FUNCTION rpr_srf_first(k int) RETURNS SETOF bigint AS $$
  SELECT count(*) OVER w
  FROM rpr_srf
  WINDOW w AS (ORDER BY v ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (B A+) DEFINE A AS v > FIRST(v, k))
$$ LANGUAGE sql STABLE;
-- 계획: 순방향 오프셋은 "runtime"으로 나타나고
-- WindowAgg 는 nestloop 안으로 인라인된다.
EXPLAIN (COSTS OFF)
SELECT g.n, max(s) FROM (VALUES (0), (1), (2)) g(n), LATERAL rpr_srf_first(g.n) s
GROUP BY g.n ORDER BY g.n;
-- 결과: k=0 은 열 개의 행 모두에 매치되고 k>=1 은 첫 번째 A를 실패하게 하므로,
-- 순방향 오프셋은 ExecInit 시점에 고정되지 않은 것이다.
SELECT g.n, max(s) AS m FROM (VALUES (0), (1), (2)) g(n), LATERAL rpr_srf_first(g.n) s
GROUP BY g.n ORDER BY g.n;
DROP FUNCTION rpr_srf_first(int);

-- 복합 내비게이션의 OUTER 오프셋도 스캔마다 다시 해소되어야 한다.  마지막
-- 오프셋에서 1 + k가 int64를 넘치므로(overflow), 그 스캔의 내비게이션은 대상
-- 행이 아예 없다.
CREATE FUNCTION rpr_srf_cmp(k int8) RETURNS SETOF bigint AS $$
  SELECT count(*) OVER w
  FROM rpr_srf
  WINDOW w AS (ORDER BY v ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A B+) DEFINE B AS v > PREV(LAST(v, 1), k))
$$ LANGUAGE sql STABLE;
-- 결과: k=1 -> 9, k=3 -> 7, overflow -> 0.  하나의 계획에서 나온 세 가지 답이
-- 각 재스캔이 자기 자신의 바깥쪽 오프셋을 해소했음을 말해 준다.  스캔이 정하는
-- trim 종류는 개수에 드러나지 않는다; 대신 rpr_explain 이 EXPLAIN ANALYZE에서
-- 이를 읽어 낸다.
SELECT g.n, max(s) AS m
FROM (VALUES (1::int8), (3::int8), (9223372036854775807::int8)) g(n),
     LATERAL rpr_srf_cmp(g.n) s
GROUP BY g.n ORDER BY g.n;
DROP FUNCTION rpr_srf_cmp(int8);
DROP FUNCTION rpr_srf_prev(int);
DROP TABLE rpr_srf;

-- ============================================================
-- B13. RPR + DEFINE 전용 매개변수 캐싱
-- ============================================================
-- DEFINE 안에서만 쓰이는 상관된 PARAM_EXEC 는 WindowAgg 의 extParam 에
-- 도달해야 한다.  그렇지 않으면 chgParam 이 DISTINCT가 그 위에 계획한
-- HashAgg 까지 전혀 전달되지 않으며, 첫 번째 바깥쪽 행을 위한 그 해시
-- 테이블이 그대로 재사용된다.  SRF는 그 인자가 PARAM_EXEC 가 되려면 lateral
-- 서브쿼리로 인라인되어야 한다; FunctionScan 계획은 어느 쪽이든 통과할 것이다.
CREATE TABLE rpr_hcache_thr (threshold int);
INSERT INTO rpr_hcache_thr VALUES (10), (200);
CREATE TABLE rpr_hcache_stock (price int);
INSERT INTO rpr_hcache_stock SELECT g FROM generate_series(1, 100) g;
CREATE FUNCTION rpr_hcache_fn(th int) RETURNS SETOF bigint LANGUAGE sql STABLE AS $$
  SELECT DISTINCT count(*) OVER w FROM rpr_hcache_stock
  WINDOW w AS (ORDER BY price ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               AFTER MATCH SKIP PAST LAST ROW
               INITIAL PATTERN (a+) DEFINE a AS price > th) $$;
-- 결과: 각 임계값은 자기 자신의 답 집합을 가진다(10 -> {0, 90}, 200 -> {0});
-- 캐시가 낡았다면 잘못된 200|90 이 추가되었을 것이다.
SELECT o.threshold, f FROM rpr_hcache_thr o, LATERAL rpr_hcache_fn(o.threshold) f
ORDER BY 1, 2;
DROP FUNCTION rpr_hcache_fn(int);
DROP TABLE rpr_hcache_thr, rpr_hcache_stock;

-- ============================================================
-- B14. RPR + 다중 윈도우 정의
-- ============================================================
-- 한 윈도우의 DEFINE 전용 컬럼(val)과 다른 윈도우의 정렬 키(grp)가 모두 select
-- 목록에 빠져 있다.  정렬 키는 junk targetlist 항목으로 계획에 도달하며,
-- DEFINE 컬럼은 targetlist에 전혀 들어가지 않고 make_window_input_target() 에
-- 의해 WindowAgg 의 입력에 추가된다.  각 윈도우는 여전히 자기 자신의 컬럼을
-- 읽어야 한다.
SELECT id, count(*) OVER w1 AS c1, count(*) OVER w2 AS c2
FROM (VALUES (1,1,10),(2,1,20)) t(id, grp, val)
WINDOW w1 AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (S U+)
        DEFINE U AS val > PREV(val)),
    w2 AS (PARTITION BY grp ORDER BY id)
ORDER BY id;

-- 평범한 ORDER BY 윈도우를 통해 도달한 같은 짝.
SELECT id, count(*) OVER w1 AS c1, count(*) OVER w2 AS c2
FROM (VALUES (1,1,10),(2,1,20)) t(id, grp, val)
WINDOW w1 AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (S U+)
        DEFINE U AS val > PREV(val)),
    w2 AS (ORDER BY grp)
ORDER BY id;

-- 반대 순서로 선언해도 위의 첫 번째 질의와 같은 행을 반환해야 한다.
SELECT id, count(*) OVER w1 AS c1, count(*) OVER w2 AS c2
FROM (VALUES (1,1,10),(2,1,20)) t(id, grp, val)
WINDOW w2 AS (PARTITION BY grp ORDER BY id),
    w1 AS (ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (S U+)
        DEFINE U AS val > PREV(val))
ORDER BY id;

-- 정리
DROP TABLE rpr_integ;
DROP TABLE rpr_integ2;
