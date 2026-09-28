-- ============================================================
-- RPR 기본 테스트
-- 행 패턴 인식(Row Pattern Recognition, ISO/IEC 19075-5) 테스트
-- ============================================================
--
-- 파서 계층:
--   키워드 사용 테스트
--   DEFINE 절 테스트
--   FRAME 옵션 테스트
--   PARTITION BY + FRAME 테스트
--   PATTERN 구문 테스트
--   수량자 테스트
--   내비게이션 함수 테스트
--   SKIP TO / INITIAL 테스트
--   직렬화/역직렬화 테스트
--   결합된 수량자 / 교대 테스트
--   오류 사례 테스트
--
-- 플래너 계층:
--   패턴 최적화 테스트
--   흡수 플래그 표시 테스트
--   흡수 분석 테스트
--   에지 케이스 테스트
--   최적화 폴백 테스트
--   플래너 통합 테스트
--   서브쿼리와 CTE 테스트
--   JOIN 테스트
--   복합 표현식 테스트
--   집합 연산 테스트
--   정렬과 그룹화 테스트
--   SQL 함수 인라인화 테스트
--   스트레스 테스트
--   오류 한계 테스트
--
-- 기여된 테스트:
--   기본 패턴 매칭
--   병리적 패턴
-- ============================================================

SET client_min_messages = WARNING;

-- ============================================================
-- 키워드 사용 테스트
-- ============================================================

-- 열 이름으로 쓰인 RPR 키워드
-- 키워드: define, initial, past, pattern, permute, seek

CREATE TABLE rpr_keywords (
    id INT,
    define INT,      -- DEFINE 키워드
    initial INT,     -- INITIAL 키워드
    past INT,        -- PAST 키워드
    pattern INT,     -- PATTERN 키워드
    permute INT,     -- PERMUTE 키워드
    seek INT,        -- SEEK 키워드
    skip INT         -- SKIP 키워드 (기존에 있던 것)
);

INSERT INTO rpr_keywords VALUES (1, 10, 20, 30, 40, 45, 50, 60);

SELECT id, define, initial, past, pattern, permute, seek, skip
FROM rpr_keywords;

DROP TABLE rpr_keywords;

-- ============================================================
-- DEFINE 절 테스트
-- ============================================================

-- 단순 열 참조들
CREATE TABLE rpr_stock_price (
    dt DATE,
    symbol TEXT,
    price NUMERIC,
    volume INT
);

INSERT INTO rpr_stock_price VALUES
    ('2024-01-01', 'AAPL', 150, 1000),
    ('2024-01-02', 'AAPL', 155, 1200),
    ('2024-01-03', 'AAPL', 152, 900),
    ('2024-01-04', 'AAPL', 160, 1500),
    ('2024-01-05', 'AAPL', 158, 1100);

-- 단순 열 참조
SELECT dt, price, COUNT(*) OVER w as cnt
FROM rpr_stock_price
WINDOW w AS (
    PARTITION BY symbol
    ORDER BY dt
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (UP+)
    DEFINE UP AS price > 150
);

-- 여러 개의 열 참조
SELECT dt, price, volume, COUNT(*) OVER w as cnt
FROM rpr_stock_price
WINDOW w AS (
    PARTITION BY symbol
    ORDER BY dt
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (GOOD+)
    DEFINE GOOD AS price > 150 AND volume > 1000
);

-- DEFINE 안의 표현식
SELECT dt, price, COUNT(*) OVER w as cnt
FROM rpr_stock_price
WINDOW w AS (
    PARTITION BY symbol
    ORDER BY dt
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (HIGH+)
    DEFINE HIGH AS price * 1.1 > 165
);

-- 산술 연산과 함수
SELECT dt, price, volume, COUNT(*) OVER w as cnt
FROM rpr_stock_price
WINDOW w AS (
    PARTITION BY symbol
    ORDER BY dt
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (CALC+)
    DEFINE CALC AS (price + volume / 100) > 160
);

DROP TABLE rpr_stock_price;

-- DEFINE 항목이 없는 패턴 변수
CREATE TABLE rpr_auto (id INT, val INT);
INSERT INTO rpr_auto VALUES (1, 10), (2, 20), (3, 30), (4, 15);

-- B는 DEFINE 항목이 없으므로 모든 행에 매치된다
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_auto
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ B*)
    DEFINE A AS val > 15
);

-- 정의되지 않은 변수가 여러 개인 경우
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_auto
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B C)
    DEFINE A AS val > 0
    -- B와 C는 DEFINE 항목이 없으므로 모든 행에 매치된다
);

-- 모든 변수를 명시적으로 정의
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_auto
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (X Y Z)
    DEFINE
        X AS val > 10,
        Y AS val > 20,
        Z AS val < 20
);

DROP TABLE rpr_auto;

-- 중복된 변수 이름
CREATE TABLE rpr_dup (id INT);
INSERT INTO rpr_dup VALUES (1), (2);

-- 중복된 DEFINE 변수 이름은 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_dup
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS id > 0, A AS id < 10
);

DROP TABLE rpr_dup;

-- 불리언 강제 변환
CREATE TABLE rpr_bool (id INT, flag BOOLEAN);
INSERT INTO rpr_bool VALUES (1, true), (2, false);

-- DEFINE 절은 불리언 표현식이어야 한다
SELECT COUNT(*) OVER w
FROM rpr_bool
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS id
);

-- 불리언 열 참조
SELECT id, flag, COUNT(*) OVER w as cnt
FROM rpr_bool
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (T+)
    DEFINE T AS flag
);

-- NULL::boolean
SELECT id, COUNT(*) OVER w as cnt
FROM rpr_bool
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (N+)
    DEFINE N AS NULL::boolean
);

-- 사용자 정의 타입을 통한 암묵적 불리언 캐스트
CREATE TYPE rpr_truthyint AS (v int);
CREATE FUNCTION rpr_truthyint_to_bool(rpr_truthyint) RETURNS boolean AS $$
  SELECT ($1).v <> 0;
$$ LANGUAGE SQL IMMUTABLE STRICT;
CREATE CAST (rpr_truthyint AS boolean)
  WITH FUNCTION rpr_truthyint_to_bool(rpr_truthyint)
  AS ASSIGNMENT;

CREATE TABLE rpr_coerce (id int, val rpr_truthyint);
INSERT INTO rpr_coerce VALUES (1, ROW(1)), (2, ROW(0)), (3, ROW(5)), (4, ROW(0));

SELECT id, val, cnt
FROM (SELECT id, val,
             COUNT(*) OVER w AS cnt
      FROM rpr_coerce
      WINDOW w AS (
          ORDER BY id
          ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
          PATTERN (A+)
          DEFINE A AS val
      )
) s ORDER BY id;

DROP TABLE rpr_coerce;
DROP CAST (rpr_truthyint AS boolean);
DROP FUNCTION rpr_truthyint_to_bool(rpr_truthyint);
DROP TYPE rpr_truthyint;

DROP TABLE rpr_bool;

-- 불리언 도메인에 대한 강제 변환은 no-op이 아니다.  래핑된 Var는 DEFINE에서만
-- 참조되더라도(select 목록에는 flag가 없음) 전파되어야 한다
CREATE DOMAIN rpr_boolish AS boolean;
CREATE TABLE rpr_domain (id int, flag rpr_boolish);
INSERT INTO rpr_domain VALUES (1, true), (2, false), (3, true);
SELECT id, COUNT(*) OVER w AS cnt
FROM rpr_domain
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS flag
);
DROP TABLE rpr_domain;
DROP DOMAIN rpr_boolish;

-- 내비게이션 연산 안에서만 참조되는 Var도 전파되어야 한다 (val은 PREV()
-- 안에서만 나타나며, 단독 피연산자나 select 목록에는 없다)
CREATE TABLE rpr_nav (id int, val int);
INSERT INTO rpr_nav VALUES (1, 0), (2, 1), (3, 0), (4, 2);
SELECT id, COUNT(*) OVER w AS cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (UP+)
    DEFINE UP AS id > PREV(val)
);
DROP TABLE rpr_nav;

-- 불리언이 아닌 DEFINE 표현식은 거부된다
CREATE TABLE rpr_noncoerce (id int, n int);
INSERT INTO rpr_noncoerce VALUES (1, 1);
SELECT id, COUNT(*) OVER w AS cnt
FROM rpr_noncoerce
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS n
);
DROP TABLE rpr_noncoerce;

-- 앞선 DEFINE 변수가 유효하더라도, 불리언이 아닌 뒤쪽 DEFINE은 그 자신이
-- 정의되는 지점에서 거부된다
CREATE TABLE rpr_noncoerce2 (id int, n int);
INSERT INTO rpr_noncoerce2 VALUES (1, 1);
SELECT id, COUNT(*) OVER w AS cnt
FROM rpr_noncoerce2
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS id > 0, B AS n
);
DROP TABLE rpr_noncoerce2;

-- 복합 표현식
CREATE TABLE rpr_complex (id INT, val1 INT, val2 INT);
INSERT INTO rpr_complex VALUES (1, 10, 20), (2, 15, 25), (3, 20, 30);

-- CASE 표현식
SELECT id, val1, val2, COUNT(*) OVER w as cnt
FROM rpr_complex
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (C+)
    DEFINE C AS CASE WHEN val1 > 10 THEN val2 > 20 ELSE false END
);

DROP TABLE rpr_complex;

-- PATTERN에 없는 추가 DEFINE 변수
CREATE TABLE rpr_unused (id INT);
INSERT INTO rpr_unused VALUES (1), (2);

-- 추가 DEFINE 변수
SELECT id, COUNT(*) OVER w as cnt
FROM rpr_unused
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS id > 0, B AS id > 5  -- B는 패턴에 없다
);

DROP TABLE rpr_unused;

-- DEFINE 조건절은 그 변수가 잠정적으로 매핑될 때만 평가된다.  A는 모든 행에서
-- false이므로 B에는 결코 도달하지 않는다.  (0 으로 나누는) B의 조건은 절대
-- 실행되어서는 안 되며, 모든 행이 매치되지 않아야 한다.
CREATE TABLE rpr_lazy (id INT, v INT);
INSERT INTO rpr_lazy VALUES (1, 1), (2, 2), (3, 3);
SELECT id, v, count(*) OVER w AS cnt
FROM rpr_lazy
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B)
    DEFINE A AS v < 0, B AS 1 / (v - v) > 0
);

DROP TABLE rpr_lazy;

-- 콜레이션을 갖는 내비게이션 결과.  두 형태 모두 파서가 인자의 콜레이션이
-- 아니라 내비게이션 노드 자체의 콜레이션을 요구하게 만든다.
CREATE TABLE rpr_navcoll (id INT, s TEXT);
INSERT INTO rpr_navcoll VALUES (1, 'a'), (2, 'B'), (3, 'c');

-- 내비게이션 결과에 적용된 COLLATE
SELECT id, s, count(*) OVER w AS cnt
FROM rpr_navcoll
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(s) COLLATE "C" < s
);

-- 내비게이션 결과에 대한 단순 CASE: 플레이스홀더는 테스트 대상 표현식으로부터
-- 자신의 콜레이션을 가져온다
SELECT id, s, count(*) OVER w AS cnt
FROM rpr_navcoll
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS CASE PREV(s) WHEN 'a' THEN true ELSE false END
);

DROP TABLE rpr_navcoll;

-- DEFINE 표현식 안의 시스템 열.  스캔만 이를 시스템 속성으로 읽으며,
-- 표현식에는 외부 Var로 도달한다.  이때도 내비게이션은 여전히 적용된다:
-- PREV(ctid)는 이 행이 아니라 매치의 이전 행이다.
CREATE TABLE rpr_navsys (i INT);
INSERT INTO rpr_navsys SELECT generate_series(1, 5);
SELECT i, count(*) OVER w AS cnt
FROM rpr_navsys
WINDOW w AS (
    ORDER BY i
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(ctid) IS DISTINCT FROM ctid
);

DROP TABLE rpr_navsys;

-- ============================================================
-- FRAME 옵션 테스트
-- ============================================================

CREATE TABLE rpr_frame (id INT, val INT);
INSERT INTO rpr_frame VALUES
    (1, 10), (2, 10), (3, 10),  -- 같은 val: 10
    (4, 20), (5, 20),           -- 같은 val: 20
    (6, 30);

-- 유효한 프레임 옵션

-- ROWS: 물리적 행 수를 센다 (1 FOLLOWING = 다음 물리적 행 1 개)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY val
    ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B?)
    DEFINE A AS val >= 0, B AS val >= 0
)
ORDER BY id;

-- 프레임은 UNBOUNDED PRECEDING이 아니라 CURRENT ROW에서 시작해야 한다
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- EXCLUDE 옵션

-- EXCLUDE는 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    EXCLUDE CURRENT ROW
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- EXCLUDE GROUP은 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    EXCLUDE GROUP
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- EXCLUDE TIES는 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    EXCLUDE TIES
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 두 규칙을 한꺼번에 어긴 경우.  프레임 모양이 먼저 확정되므로 보고에는 그
-- 모양이 이름으로 나타나며, EXCLUDE 절은 재작성 과정에서 살아남지 못할
-- 수 있다.
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    EXCLUDE TIES
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- range 프레임은 RPR과 함께 쓸 수 없다
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- GROUPS 프레임은 RPR과 함께 쓸 수 없다
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    GROUPS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 프레임 절을 생략하면 표준 기본값인 RANGE BETWEEN UNBOUNDED PRECEDING AND
-- CURRENT ROW가 남으며, 이는 세 규칙을 한꺼번에 어긴다.  보고는 프레임이
-- 어떠해야 하는지를 말하는 하나만 나온다.
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 프레임은 offset PRECEDING이 아니라 CURRENT ROW에서 시작해야 한다
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN 1 PRECEDING AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 프레임은 offset FOLLOWING이 아니라 CURRENT ROW에서 시작해야 한다
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- ERROR: 끝이 시작보다 앞섬: CURRENT ROW AND 1 PRECEDING
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 1 PRECEDING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- ERROR: 끝이 시작보다 앞섬: CURRENT ROW AND UNBOUNDED PRECEDING
SELECT COUNT(*) OVER w
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED PRECEDING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 한 행짜리 프레임: CURRENT ROW AND CURRENT ROW는 거부된다 (표준은 UNBOUNDED
-- FOLLOWING이나 양의 offset FOLLOWING만 허용한다).
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND CURRENT ROW
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A)
    DEFINE A AS val > 0
);

-- 오프셋 0: CURRENT ROW AND 0 FOLLOWING은 같은 한 행짜리 프레임을 나타내며
-- 마찬가지로 거부된다 (실행 시점에 검출된다).
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 0 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A)
    DEFINE A AS val > 0
);

-- 상수가 아닌 프레임 끝 오프셋은 허용되며, 값이 0 이면 위의 리터럴 0 이
-- 도달하는 것과 같은 실행 시점 검사에 의해 거부된다.
PREPARE rpr_end_offset(int8) AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND $1 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A)
    DEFINE A AS val > 0
);
EXECUTE rpr_end_offset(2);
EXECUTE rpr_end_offset(0);
DEALLOCATE rpr_end_offset;

-- 큰 오프셋: CURRENT ROW AND 1000 FOLLOWING
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 1000 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 최대 오프셋: CURRENT ROW AND 2147483646 FOLLOWING (INT_MAX - 1)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 2147483646 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- int64 프레임 끝 오버플로: 매우 큰 FOLLOWING 오프셋은 파티션 끝으로
-- 클램프되어야 한다 (matchStartRow + offset + 1 이 int64 를 오버플로하므로
-- 클램프가 UNBOUNDED FOLLOWING처럼 동작하게 만든다).  "frameOffset + 1"
-- 부분식에서의 부호 있는 정수 오버플로(정의되지 않은 동작)를 막는다.  cnt 값은
-- 같은 데이터에 대해 UNBOUNDED FOLLOWING 결과와 일치해야 한다.
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 9223372036854775806 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- range 프레임은 RPR과 함께 쓸 수 없다
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY val
    RANGE BETWEEN CURRENT ROW AND 10 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B?)
    DEFINE A AS val >= 0, B AS val >= 0
);

-- RPR과 함께 쓰는 GROUPS 프레임 (허용되지 않음)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_frame
WINDOW w AS (
    ORDER BY val
    GROUPS BETWEEN CURRENT ROW AND 1 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B?)
    DEFINE A AS val >= 0, B AS val >= 0
);

DROP TABLE rpr_frame;

-- ============================================================
-- PARTITION BY + FRAME 테스트
-- ============================================================

-- RPR과 함께 쓰는 PARTITION BY가 올바르게 파티셔닝되는지 확인하는 테스트
CREATE TABLE rpr_partition (id INT, grp INT, val INT);
INSERT INTO rpr_partition VALUES
    (1, 1, 10), (2, 1, 20), (3, 1, 30),
    (4, 2, 15), (5, 2, 25), (6, 2, 35);

-- ROWS 프레임과 함께 쓰는 PARTITION BY
SELECT id, grp, val, COUNT(*) OVER w as cnt
FROM rpr_partition
WINDOW w AS (
    PARTITION BY grp
    ORDER BY val
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B+)
    DEFINE A AS val >= 10, B AS val > 15
);

-- RANGE 프레임과 함께 쓰는 PARTITION BY
SELECT id, grp, val, COUNT(*) OVER w as cnt
FROM rpr_partition
WINDOW w AS (
    PARTITION BY grp
    ORDER BY val
    RANGE BETWEEN CURRENT ROW AND 10 FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B?)
    DEFINE A AS val >= 10, B AS val >= 20
);

DROP TABLE rpr_partition;

-- ============================================================
-- PATTERN 구문 테스트
-- ============================================================

CREATE TABLE rpr_pattern (id INT, val INT);
INSERT INTO rpr_pattern VALUES
    (1, 5), (2, 10), (3, 15), (4, 20), (5, 25),
    (6, 30), (7, 35), (8, 40), (9, 45), (10, 50);

-- 교대 (|)

-- 여러 대안
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_pattern
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ | B+ | C+)
    DEFINE A AS val > 35, B AS val BETWEEN 15 AND 35, C AS val < 15
);

-- 그룹화

-- 수량자를 가진 중첩 그룹화
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_pattern
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (((A B) C)+)
    DEFINE A AS val > 10, B AS val > 20, C AS val > 30
);

-- 시퀀스

-- 여러 요소로 이루어진 시퀀스
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_pattern
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B C D E)
    DEFINE
        A AS val < 15,
        B AS val BETWEEN 15 AND 25,
        C AS val BETWEEN 25 AND 35,
        D AS val BETWEEN 35 AND 45,
        E AS val >= 45
);

-- 복합 조합

-- 그룹화를 포함한 교대
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_pattern
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A B) | (C D))
    DEFINE A AS val < 20, B AS val >= 20, C AS val < 30, D AS val >= 30
);

-- 교대 + 시퀀스 + 그룹화
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_pattern
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (START (UP{2,} DOWN? | FLAT+) FINISH)
    DEFINE
        START AS val >= 0,
        UP AS val > 20,
        DOWN AS val <= 30,
        FLAT AS val BETWEEN 25 AND 35,
        FINISH AS val > 40
);

-- 그룹 안에 중첩된 교대
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_pattern
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A | B) (C | D))
    DEFINE A AS val < 15, B AS val BETWEEN 15 AND 25, C AS val BETWEEN 25 AND 35, D AS val > 35
);

DROP TABLE rpr_pattern;

-- ============================================================
-- 수량자 테스트
-- ============================================================

CREATE TABLE rpr_quant (id INT, val INT);
INSERT INTO rpr_quant VALUES
    (1, 10), (2, 20), (3, 30), (4, 40), (5, 50),
    (6, 60), (7, 70), (8, 80), (9, 90), (10, 100);

-- 기본 탐욕적 수량자

-- * (0 개 이상)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A*)
    DEFINE A AS val > 0
);

-- + (1 개 이상)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 50
);

-- ? (0 개 또는 1 개)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A?)
    DEFINE A AS val = 50
);

-- 경계 사례 수량자

-- {0}은 허용되지 않는다 (최솟값은 1 이상이어야 한다)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{0} B)
    DEFINE A AS val > 1000, B AS val > 0
);

-- {0,0}은 허용되지 않는다 (최댓값은 1 이상이어야 한다)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{0,0} B)
    DEFINE A AS val > 1000, B AS val > 0
);

-- {0,1} (?와 동등)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{0,1})
    DEFINE A AS val = 50
);

-- 정확한 수량자 {n}

-- {3} (대표적인 정확한 수량자)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{3})
    DEFINE A AS val > 0
);

-- 범위 수량자 {n,}

-- {2,} (대표적인 n개 이상)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2,})
    DEFINE A AS val > 40
);

-- 상한 수량자 {,m}

-- {,3} (대표적인 m개 이하)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{,3})
    DEFINE A AS val > 0
);

-- 범위 수량자 {n,m}

-- {3,7} (대표적인 범위)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_quant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{3,7})
    DEFINE A AS val > 0
);

DROP TABLE rpr_quant;

-- 소극적 수량자
CREATE TABLE rpr_reluctant (id INT, val INT);
INSERT INTO rpr_reluctant VALUES (1, 10), (2, 20), (3, 30);

-- 같은 변수에 대해 탐욕적 수량자 뒤에 소극적 수량자가 오는 경우는 병합되어서는
-- 안 된다: 병합된 표기 A{2,3}과 A{1,4}는 두 자리에서 멈추는 세 행 모두에
-- 매치되므로, 병합하면 선호되는 매치가 달라진다.
SELECT id, count(*) OVER w FROM rpr_reluctant
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2} A??) DEFINE A AS TRUE);

SELECT id, count(*) OVER w FROM rpr_reluctant
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{1,2} A{0,2}?) DEFINE A AS TRUE);

-- 연쇄: 소극적인 중간 VAR는 양쪽에서 병합을 막아야 한다.  병합된 A{1,3}은 세
-- 행 모두에 매치될 것이다
SELECT id, count(*) OVER w FROM rpr_reluctant
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A? A?? A) DEFINE A AS TRUE);

-- *? (0 개 이상, 소극적)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A*?)
    DEFINE A AS val > 0
);

-- +? (1 개 이상, 소극적)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+?)
    DEFINE A AS val > 0
);

-- ?? (0 개 또는 1 개, 소극적)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A??)
    DEFINE A AS val > 0
);

-- {n,}? (n개 이상, 소극적)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2,}?)
    DEFINE A AS val > 0
);

-- {n,m}? (n개에서 m개, 소극적)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1,3}?)
    DEFINE A AS val > 0
);

-- {n}?  (정확히 n개): min == max이므로 소극적 플래그는 제거되고 계획은 A{2}와
-- 구별할 수 없다.  고정된 개수는 더 짧은 매치가 없으므로 결과는 어느
-- 쪽이든 같다.
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2}?)
    DEFINE A AS val > 0
);

-- {,m}? (m개 이하, 소극적)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{,3}?)
    DEFINE A AS val > 0
);

-- {2}+ ({2}?가 되어야 하며 {2}+가 아니다)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2}+)
    DEFINE A AS val > 0
);

-- {2,}* ({2,}?가 되어야 하며 {2,}*가 아니다)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2,}*)
    DEFINE A AS val > 0
);

-- {,3}* ({,3}?가 되어야 하며 {,3}*가 아니다)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{,3}*)
    DEFINE A AS val > 0
);

-- {1,3}+ ({1,3}?가 되어야 하며 {1,3}+가 아니다)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1,3}+)
    DEFINE A AS val > 0
);

-- 소극적 수량자의 경계 오류

-- 음수 하한은 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{-1}?)
    DEFINE A AS val > 0
);

-- ERROR: 수량자 상한이 한계를 초과함
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2147483647}?)
    DEFINE A AS val > 0
);

-- 음수 하한은 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{-1,}?)
    DEFINE A AS val > 0
);

-- ERROR: 수량자 하한이 한계를 초과함
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2147483647,}?)
    DEFINE A AS val > 0
);

-- 0 상한은 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{,0}?)
    DEFINE A AS val > 0
);

-- ERROR: {,2147483647}? (범위의 상한이 한계를 초과함)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{,2147483647}?)
    DEFINE A AS val > 0
);

-- ERROR: {-1,3}? (범위의 음수 하한은 허용되지 않음)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{-1,3}?)
    DEFINE A AS val > 0
);

-- ERROR: {1,2147483647}? (범위의 상한이 한계를 초과함)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1,2147483647}?)
    DEFINE A AS val > 0
);

-- ERROR: {5,3}? (min > max는 허용되지 않음)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{5,3}?)
    DEFINE A AS val > 0
);

-- 토큰으로 분리된 소극적 수량자 (수량자와 ? 사이의 공백) 수량자와 "?" 사이의
-- 공백은 의미가 없다: 아래 각 형태는 위쪽의 분리되지 않은 대응 형태가 반환하는
-- 것과 정확히 같은 값을 반환한다.

-- * ? (토큰으로 분리됨)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A* ?)
    DEFINE A AS val > 0
);

-- + ? (토큰으로 분리됨)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ ?)
    DEFINE A AS val > 0
);

-- {2,} ? (토큰으로 분리됨)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2,} ?)
    DEFINE A AS val > 0
);

-- * + (허용되지 않는 조합)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A* +)
    DEFINE A AS val > 0
);

-- + * (허용되지 않는 조합)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ *)
    DEFINE A AS val > 0
);

-- ? ? (?? 소극적 수량자로 해석됨)
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A? ?)
    DEFINE A AS val > 0
);

-- 첫 토큰이 "?"가 아닌 연산자 토큰 두 개: 문제가 되는 쪽은 두 번째이므로
-- 그것이 이름으로 지목되고 커서도 그것을 가리킨다
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A *? ?)
    DEFINE A AS val > 0
);

-- "|"로 끝나는 첫 토큰은 수량자와 교대 연산자가 결합된 것이므로, 그 뒤에는
-- 패턴이 와야 하고 Op는 결코 패턴이 될 수 없다.  보고는 그 쌍이 아니라 교대를
-- 이름으로 지목한다: "A* ?"는 받아들여지므로, 그 쌍을 이름으로 지목하면 문법이
-- 받아들이는 무언가를 가리키게 된다.
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A *| ?)
    DEFINE A AS val > 0
);

-- 결합된 두 문자짜리 수량자에도 마찬가지이며, 이 쌍을 이름으로 지목하려면
-- "*?|"에서 "*?"를 지어내야 한다
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A *?| ??)
    DEFINE A AS val > 0
);

-- 아예 수량자가 아닌 첫 토큰은 그 자체가 문제가 되는 대상이므로, 단독으로
-- 나타났을 때와 같은 방식으로 보고된다
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A ?+ ?)
    DEFINE A AS val > 0
);

-- 두 토큰은 따로 보고되므로, 보고가 한 번도 입력되지 않은 표기로 그것들을
-- 결합할 수 없다
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A ?? || B)
    DEFINE A AS val > 0, B AS val > 1
);

-- 끝에 붙은 "|"는 수량자가 아니라 교대에 속하므로, 보고에서는 빠진다
SELECT COUNT(*) OVER w
FROM rpr_reluctant
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A ?? ?|B)
    DEFINE A AS val > 0, B AS val > 1
);

DROP TABLE rpr_reluctant;

-- 수량자 경계 조건

CREATE TABLE rpr_bounds (id INT);
INSERT INTO rpr_bounds VALUES (1), (2);

-- ERROR: 수량자 하한은 상한을 넘을 수 없다
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{5,3})
    DEFINE A AS id > 0
);

-- 큰 한계값
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1000,2000})
    DEFINE A AS id > 0
);

-- 매우 큰 한계값
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{100000})
    DEFINE A AS id > 0
);

-- INT_MAX - 1 = 2147483646 (한계값)
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2147483646})
    DEFINE A AS id > 0
);

-- ERROR: 수량자 상한이 한계를 초과함
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2147483647})
    DEFINE A AS id > 0
);

-- {n,} 경계 오류

-- ERROR: {n,}에서 음수 하한은 허용되지 않음
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{-1,})
    DEFINE A AS id > 0
);

-- ERROR: 수량자 하한이 한계를 초과함
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2147483647,})
    DEFINE A AS id > 0
);

-- {,m} 경계 오류

-- {,m}에서 0 상한
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{,0})
    DEFINE A AS id > 0
);

-- ERROR: 수량자 상한이 한계를 초과함
SELECT COUNT(*) OVER w
FROM rpr_bounds
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{,2147483647})
    DEFINE A AS id > 0
);

DROP TABLE rpr_bounds;

-- 패턴 요소 개수 경계 (FIN 마커를 포함하여 최대 32767 개).  서로 다른 변수를
-- 번갈아 쓰면 최적화기가 연속된 요소들을 병합하지 못하므로, "A B" 쌍마다 요소
-- 2 개가 생긴다.  수천 개짜리 토큰으로 이루어진 패턴이 생성되므로 예상 출력이
-- 넘치지 않도록 ECHO를 끈다.
--   16383 쌍         -> 32766 + FIN 1 개 = 32767 = 최대, 허용됨.
--   16383 쌍 + A 1 개 -> 32767 + FIN 1 개 = 32768 > 최대, 거부됨.
\set ECHO none
SELECT format($$SELECT count(*) OVER w FROM (SELECT 1 i) t
  WINDOW w AS (ORDER BY i ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  INITIAL PATTERN (%s) DEFINE A AS TRUE, B AS TRUE)$$,
  repeat('A B ', 16383)) \gexec
SELECT format($$SELECT count(*) OVER w FROM (SELECT 1 i) t
  WINDOW w AS (ORDER BY i ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  INITIAL PATTERN (%s A) DEFINE A AS TRUE, B AS TRUE)$$,
  repeat('A B ', 16383)) \gexec
\set ECHO all

-- ============================================================
-- 내비게이션 함수 테스트 (PREV / NEXT / FIRST / LAST)
-- ============================================================
CREATE TEMP TABLE rpr_nav0 (id int, v int);
INSERT INTO rpr_nav0 SELECT g, g*10 FROM generate_series(1, 5) g;

-- 같은 캐시된 제네릭 플랜에 대해 서로 다른 오프셋 매개변수를 가진, 동시에 열린
-- 두 개의 포털.
--
-- 매개변수화된 커서 'c'는 하나의 plpgsql 문으로 컴파일되어 SPI 캐시 플랜
-- 하나가 된다.  재귀 호출은 (다른 오프셋으로) 같은 플랜의 두 번째 포털을
-- OPEN하는데, 이때 외부 포털은 이미 시작되었지만 아직 FETCH되지 않은 상태다.
CREATE OR REPLACE FUNCTION rpr_nested(p_off int, depth int)
RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
  c CURSOR (o int) FOR
    SELECT id, count(*) OVER w AS cnt
    FROM rpr_nav0
    WINDOW w AS (ORDER BY id
                 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                 PATTERN (A)
                 DEFINE A AS PREV(v, o) IS NULL);
  r record;
BEGIN
  OPEN c(p_off);
  IF depth > 0 THEN
    RETURN QUERY SELECT * FROM rpr_nested(p_off + 2, depth - 1);
  END IF;

  LOOP
    FETCH c INTO r;
    EXIT WHEN NOT FOUND;
    RETURN NEXT format('off=%s id=%s cnt=%s', p_off, r.id, r.cnt);
  END LOOP;
  CLOSE c;
END $$;

SET plan_cache_mode = force_generic_plan;
SELECT * FROM rpr_nested(1, 1);
RESET plan_cache_mode;

DROP FUNCTION rpr_nested(int, int);

CREATE TABLE rpr_nav (id INT, val INT);
INSERT INTO rpr_nav VALUES
    (1, 10), (2, 20), (3, 15), (4, 25), (5, 30);

-- 대상 행이 범위를 벗어나거나 존재하지 않을 때 내부 인자 표현식의 평가를
-- 피한다.  PREV는 파티션의 첫 행에서, NEXT는 마지막 행에서 실패하므로 두
-- 방향을 따로 검사한다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(val is not null) is null);

SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS NEXT(val is not null) is null);

-- PATTERN (A)에서는 FIRST와 LAST가 실패할 수 없다: 매치가 한 행 길이이므로
-- 대상은 현재 행이고 슬롯 교체는 생략된다. 이 두 테스트는 그 경로를 실행하며,
-- 아래 쿼리는 그것이 무엇을 쓰는지 고정한다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS LAST(val is not null) is null);

SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS FIRST(val is not null) is null);

-- 생략된 경로도 대상 행이 존재한다고 보고해야 한다.  내비게이션이 실패한
-- 스캔에서 온 resnull이 여전히 null일 수 있기 때문이다.  여기서는 내비게이션이
-- DEFINE 전체이므로 그 사이에 resnull을 덮어쓰는 것이 없고, 함수를
-- 인라인화하면 오프셋이 매개변수가 된다: 1 은 실패하고, 0 은 생략된다.
CREATE FUNCTION rpr_nav_off(k int) RETURNS SETOF bigint LANGUAGE sql STABLE AS $$
  SELECT count(*) OVER w FROM rpr_nav WHERE id = 1
  WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
               PATTERN (A) DEFINE A AS PREV(val > 0, k)) $$;
SELECT o.k, f FROM (VALUES (1), (0)) o(k), LATERAL rpr_nav_off(o.k) f;
DROP FUNCTION rpr_nav_off(int);

-- 더 긴 패턴에서는 FIRST와 LAST가 실패할 수 있다.  매치의 첫 행에서는
-- currentpos가 match_start 값과 같으므로 오프셋 1 은 어느 방향으로도 매치를
-- 벗어나며, 복합 형태는 내부 내비게이션에서 실패하는데 이는 단순 형태가 넘는
-- 경계와는 별개다.  인자는 null을 전파하지 않으므로, 존재하지 않는 행과 null로
-- 이루어진 행은 구별된다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS LAST(val is not null, 1) is null);

SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS FIRST(val is not null, 1) is null);

SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS PREV(FIRST(val is not null, 1), 2) is null);

SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS PREV(LAST(val is not null, 1), 2) is null);

-- PREV(val is not null) 사례의 중복이 아니다: 여기서 인자는 그 경우가 false인
-- 곳에서 true이며, 존재하지 않는 행은 여전히 둘 다를 이겨야 한다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(val is null) is null);

-- 인자를 건너뛰는지는 데이터에 따라 달라진다: PREV가 실패하는 행으로 한정하면
-- 그 안의 0 으로 나누기는 결코 실행되지 않지만, 테이블 전체에서는 NEXT가
-- 마지막 행을 제외한 모든 행에 도달하며 그때는 실행된다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t WHERE id = 1
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(val / 0) > 0);

SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS NEXT(val / 0) > 0);

-- 인자의 상수 부분식은 미리 접혀 없어지므로, 패턴은 행마다 그것을 다시
-- 계산하지 않는다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS PREV(val + 2 * 3) > 0);

-- 상수 부분식을 접으면 인자 전체로는 일어나지 않았을 오류가 날 수 있다: 위의
-- val / 0 과 달리 1 / 0 은 행에 의존하지 않으므로, PREV가 실패하는 행에서도
-- 계획 시점에 도달한다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav t
WHERE id = 1
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(val + 1 / 0) > 0);

-- 여기서는 null이 IS NULL이 아니라 DEFINE 조건절 자체에 도달한다 대상 행
-- 전체가 NULL이었다면 v IS NULL이 true가 되어 첫 행에 매치되었을 것이므로, 이
-- 테스트는 같은 동작의 조건절 쪽을 고정한다.
WITH t(id, v) AS (VALUES (1, 10), (2, 20))
SELECT id, count(*) OVER w AS cnt
FROM t
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(v IS NULL));

-- VALUES를 풀업하면 v 자리에 10 이 대입되는데, 이는 내비게이션 아래에서 그
-- 열이 의미하던 바가 아니다: 인자는 내비게이션이 도달한 행을 읽는 것이지 이
-- 행을 읽는 것이 아니다.  대입 결과는 접혀 없어지지 않고
-- PlaceHolderVar 로 래핑된다.
WITH t(id, v) AS (VALUES (1, 10))
SELECT id, count(*) OVER w AS cnt
FROM t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(v IS NULL));

-- 그 래핑이 바로 이 쿼리가 오류를 내지 않게 하는 이유다: 제수는 상수이지만
-- 피제수가 접혀 없어지지 않으므로 나눗셈은 실행 시점까지 그대로 남고, 그곳에서
-- PREV는 내비게이션할 행이 없어 결코 도달하지 않는다.
WITH t(id, v) AS (VALUES (1, 10))
SELECT id, count(*) OVER w AS cnt
FROM t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(v / 0) > 0);

-- 풀업된 서브쿼리와 상수로 접힌 함수 RTE는 내비게이션 인자에 같은 방식으로
-- 도달하므로 둘 다 마찬가지로 래핑된다.
SELECT id, count(*) OVER w AS cnt
FROM (SELECT 1 AS id, 10 AS v) t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(v / 0) > 0);

SELECT count(*) OVER w AS cnt
FROM abs(-10) AS v
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS PREV(v / 0) > 0);

-- 보호되는 것은 인자뿐이다.  내비게이션 한 단계 바깥에서는 같은 열이 다른
-- 곳에서와 똑같이 대입되고 접혀 없어지며, 나눗셈은 계획 시점에 오류를 낸다 --
-- 패턴이 전혀 없는, 같은 한 행짜리 VALUES에 대한 같은
-- WHERE절에서와 마찬가지다.
WITH t(id, v) AS (VALUES (1, 10))
SELECT id, count(*) OVER w AS cnt
FROM t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A) DEFINE A AS v / 0 > 0);

-- 여전히 행에 의존하는 대입 결과는 래핑되지 않은 채로 남는다.  그것이
-- 내비게이션이 도달하는 행이 무엇이든 그 열이 의미하는 바이기 때문이다.
SELECT id, count(*) OVER w AS cnt
FROM (SELECT id, val + 1 AS v FROM rpr_nav) t
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS PREV(v) > 0);

-- 중첩: 내부 내비게이션의 인자는 외부 내비게이션의 인자보다 아래에 있으므로,
-- 그곳의 열도 마찬가지로 래핑된다.
WITH t(id, v) AS (VALUES (1, 10))
SELECT id, count(*) OVER w AS cnt
FROM t
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A) DEFINE A AS PREV(LAST(v / 0, 1), 2) > 0);

-- eval_const_expressions()는 자신에게 주어진 모든 표현식에 대해 몇 가지
-- 재작성을 반드시 수행해야 한다 -- CollateExpr 는 RelabelType 이 되고, 이름
-- 붙은 인자는 위치 인자가 되며, 생략된 기본값은 채워진다 -- 그리고 실행기는 이
-- 세 가지 모두에 의존하므로 이들은 최적화가 아니라 필수 사항이다.  아래 세
-- 테스트는 이 재작성이 내비게이션 인자 안쪽까지 도달할 때만 실행기에 이르며,
-- 각각은 내비게이션 한 단계 바깥의 같은 표현식이 반환하는 것과 같은
-- 값을 반환한다.
CREATE TABLE rpr_nav_txt (id int, s text);
INSERT INTO rpr_nav_txt VALUES (1, 'b'), (2, 'c'), (3, 'a');
CREATE FUNCTION rpr_nav_named(a int, b int) RETURNS int
    LANGUAGE sql IMMUTABLE AS 'SELECT $1 * 10 + $2';
CREATE FUNCTION rpr_nav_dflt(a int, b int DEFAULT 100) RETURNS int
    LANGUAGE sql IMMUTABLE AS 'SELECT $2';

-- 내비게이션 아래의 COLLATE: 실행기에는 CollateExpr 단계가 없으므로
-- RelabelType 재작성이 여기까지 도달해야 한다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav_txt
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS PREV(s COLLATE "C") > 'a');

-- 내비게이션 아래의 이름 붙은 인자: 실행기에는 NamedArgExpr 단계가 없다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS PREV(rpr_nav_named(b => 7, a => val)) > 0);

-- 내비게이션 아래의 생략된 기본값: 채워 넣지 않으면 호출이 콜리가 읽는 것보다
-- 하나 적은 인자로 초기화된다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_nav
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+) DEFINE A AS PREV(rpr_nav_dflt(val)) = 100);

DROP FUNCTION rpr_nav_dflt(int, int);
DROP FUNCTION rpr_nav_named(int, int);
DROP TABLE rpr_nav_txt;

-- 내비게이션 오프셋은 어떤 입력 행도 읽기 전에 스캔의 맨 앞에서 한 번
-- 결정되므로, 내비게이션되는 인자와 같은 방식으로 윈도우 입력에 매칭시켜서는
-- 안 된다.  아래 두 테스트는 오프셋을 윈도우 ORDER BY 키와, 그리고 GROUP BY
-- 표현식과 똑같이 표기하는데, 이것이 매칭을 가능하게 만드는 조건이다.
CREATE TABLE rpr_navoff (id int, val int);
INSERT INTO rpr_navoff VALUES (1, 10), (2, 20), (3, 15), (4, 30), (5, 5);

SELECT id, val, count(*) OVER w AS cnt
FROM rpr_navoff
WINDOW w AS (ORDER BY (extract(hour from localtimestamp)::int * 0 + 1), id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE B AS val > PREV(val, (extract(hour from localtimestamp)::int * 0 + 1)));

-- 대조군: 윈도우 입력의 어떤 것과도 일치하지 않는 오프셋.
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_navoff
WINDOW w AS (ORDER BY (extract(hour from localtimestamp)::int * 0 + 1), id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE B AS val > PREV(val, (extract(hour from localtimestamp)::int * 0 + 2)));

SELECT id, val, count(*) OVER w AS cnt
FROM rpr_navoff
GROUP BY GROUPING SETS ((id, val, ((random() * 0)::bigint + 1)),
                        (id,      ((random() * 0)::bigint + 1)))
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE B AS val > PREV(val, (random() * 0)::bigint + 1))
ORDER BY id, val;

DROP TABLE rpr_navoff;

-- PREV 함수 - 패턴 안에서 이전 행을 참조
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE
        A AS val > 0,
        B AS val > PREV(val)
);

-- NEXT 함수 - 패턴 안에서 다음 행을 참조
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ B)
    DEFINE
        A AS val < NEXT(val),
        B AS val > 0
);

-- PREV와 NEXT를 함께 사용
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B C)
    DEFINE
        A AS val > 0,
        B AS val > PREV(val) AND val < NEXT(val),
        C AS val > PREV(val)
);

-- PREV 함수는 DEFINE 밖에서 쓸 수 없다
SELECT PREV(id), id, val, COUNT(*) OVER w as cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE
        A AS val > 0,
        B AS val > PREV(val)
);

-- NEXT 함수는 DEFINE 밖에서 쓸 수 없다
SELECT NEXT(id), id, val, COUNT(*) OVER w as cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE
        A AS val > 0,
        B AS val > PREV(val)
);

-- FIRST 함수 - match_start 행을 참조
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE
        A AS val > 0,
        B AS val > FIRST(val)
);

-- 오프셋 없는 LAST 함수 - 현재 행의 값과 동등
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE
        A AS val > 0,
        B AS LAST(val) > PREV(val)
);

-- FIRST와 LAST를 함께 사용
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_nav
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE
        A AS val > 0,
        B AS val > FIRST(val) AND LAST(val) > PREV(val)
);

-- FIRST 함수는 DEFINE 밖에서 쓸 수 없다
SELECT FIRST(id), id, val FROM rpr_nav;

-- LAST 함수는 DEFINE 밖에서 쓸 수 없다
SELECT LAST(id), id, val FROM rpr_nav;

DROP TABLE rpr_nav;

-- 이름공간: prev/next/first/last는 내비게이션 함수이며, 일반 함수가 아니다
CREATE SCHEMA rpr_navns;
SET search_path TO rpr_navns, public;
CREATE TABLE rpr_nav_rows (g text, id int, val int);
INSERT INTO rpr_nav_rows VALUES ('x', 1, 100), ('x', 2, 200), ('x', 3, 150),
                      ('x', 4, 140), ('x', 5, 150);

-- DEFINE 밖에서는 이들이 평범한 식별자이며 아무것도 가리키지 못한다
SELECT prev(val) FROM rpr_nav_rows;
SELECT next(val) FROM rpr_nav_rows;
SELECT prev(val, 2) FROM rpr_nav_rows;
SELECT next(val, 2) FROM rpr_nav_rows;
SELECT first(val) FROM rpr_nav_rows;
SELECT last(val) FROM rpr_nav_rows;
SELECT first(val, 1) FROM rpr_nav_rows;
-- 스키마로 한정한 호출도 마찬가지로 (실패하는) 평범한 함수 조회일 뿐이다
SELECT pg_catalog.prev(val) FROM rpr_nav_rows;

-- DEFINE 밖에서는 그 이름의 사용자 정의 함수를 호출할 수 있다
CREATE FUNCTION next(numeric) RETURNS numeric AS 'SELECT -999::numeric'
  LANGUAGE sql IMMUTABLE;
SELECT next(10);

-- DEFINE 안에서는 사용자 prev()가 존재하든 말든 한정되지 않은
-- PREV는 내비게이션이다
SELECT id, val, count(*) OVER w AS cnt, last_value(id) OVER w AS last_id
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (START UP+)
    DEFINE START AS TRUE, UP AS val > PREV(val))
  ORDER BY id;

-- 한정된 호출은 함수를 호출하므로 그 휘발성이 여전히 중요하다
-- VOLATILE: 한정되지 않으면 내비게이션이고, 한정되면 접혀 없어지지 않는
-- 한 거부된다
CREATE FUNCTION prev(integer) RETURNS integer
  LANGUAGE plpgsql VOLATILE AS 'BEGIN RETURN -999; END';
SELECT id, val, count(*) OVER w AS cnt, last_value(id) OVER w AS last_id
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (START UP+)
    DEFINE START AS TRUE, UP AS val > PREV(val))
  ORDER BY id;
SELECT id, val, count(*) OVER w AS cnt, last_value(id) OVER w AS last_id
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+)
    DEFINE A AS rpr_navns.prev(val) = -999)
  ORDER BY id;
-- SQL 본문이 인라인화되어 상수로 접히므로, 검사가 찾아낼 휘발성 호출이
-- 남지 않는다
CREATE OR REPLACE FUNCTION prev(integer) RETURNS integer AS 'SELECT -999'
  LANGUAGE sql VOLATILE;
SELECT id, val, count(*) OVER w AS cnt, last_value(id) OVER w AS last_id
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+)
    DEFINE A AS rpr_navns.prev(val) = -999)
  ORDER BY id;

-- OVER가 윈도우를 참조하지 않으므로, 서브쿼리를 평탄화하면 검사가 실행되기
-- 전에 그것이 사라진다.  참조되지 않는 CTE가 결코 계획되지 않는 것과
-- 같은 방식이다
SELECT id FROM (
 SELECT id FROM rpr_nav_rows
 WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS random() > 0.5)) s
ORDER BY id;

-- ERROR: OFFSET 0 이 서브쿼리를 남겨두므로 서브쿼리는 계획되고, 최상위의
-- 참조되지 않는 윈도우에서와 마찬가지로 어떤 OVER도 그 윈도우를 참조하지
-- 않는다고 확정되기 전에 검사가 그 DEFINE에 도달한다
SELECT id FROM (
 SELECT id FROM rpr_nav_rows
 WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS random() > 0.5) OFFSET 0) sub;

-- ERROR: 윈도우를 참조하는 OVER가 OFFSET 0 없이도 서브쿼리를 남겨두며, 그
-- DEFINE도 같은 방식으로 검사된다
SELECT id, c FROM (
 SELECT id, count(*) OVER w AS c FROM rpr_nav_rows
 WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS random() > 0.5)) sub;

-- WHERE false를 쓴 같은 쿼리는 서브쿼리 rel을 더미로 만들므로, 플래너는 그것을
-- 계획하지 않고 그 DEFINE을 들여다보는 곳도 없다
SELECT id, c FROM (
 SELECT id, count(*) OVER w AS c FROM rpr_nav_rows
 WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS random() > 0.5)) sub
WHERE false;

-- 윈도우는 실행되지만, 휘발성 호출은 검사 전에 접혀 없어지는 죽은 CASE 분기
-- 안에 있으므로 검사가 찾아낼 휘발성 요소가 남지 않는다
SELECT id, count(*) OVER w AS c FROM rpr_nav_rows
 WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS CASE WHEN false THEN random()::int > 0
                                  ELSE val > 5 END)
ORDER BY id;

-- ERROR: 폴딩은 파스 분석이 본 적 없는 휘발성 요소를 끼워 넣을 수 있다 -- 기본
-- 인자가 휘발성인 STABLE 함수가 그렇다 -- 그리고 검사는 그것을 잡아낼 만큼
-- 늦게 실행된다
CREATE FUNCTION rpr_off_leak(n bigint DEFAULT (random() * 5)::bigint)
  RETURNS bigint LANGUAGE sql STABLE AS 'SELECT n';
SELECT count(*) OVER w FROM generate_series(1, 100) g(v)
  WINDOW w AS (ORDER BY v ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS v > PREV(v, rpr_off_leak()));
DROP FUNCTION rpr_off_leak(bigint);


-- UNION ALL의 leaf도 다른 서브쿼리와 마찬가지로 평탄화되므로, 참조되지 않는 그
-- 윈도우도 같은 길을 간다
SELECT id FROM (
 SELECT id FROM rpr_nav_rows
 WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS random() > 0.5)
 UNION ALL
 SELECT id FROM rpr_nav_rows) s;

-- 참조되지 않는 CTE는 결코 계획되지 않으므로, 그 DEFINE을 들여다보는 곳도 없다
WITH unused AS (
 SELECT id FROM rpr_nav_rows
 WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS random() > 0.5))
SELECT 1;

-- ERROR: 참조하면 CTE가 계획되고, 검사는 그곳의 DEFINE에 도달한다
WITH used AS (
 SELECT id FROM rpr_nav_rows
 WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS random() > 0.5))
SELECT count(*) FROM used;

DROP FUNCTION prev(integer);
-- IMMUTABLE: 한정되지 않으면 내비게이션이고, 한정되면 예외 통로이며 성공한다
CREATE FUNCTION prev(integer) RETURNS integer AS 'SELECT -999'
  LANGUAGE sql IMMUTABLE;
SELECT id, val, count(*) OVER w AS cnt, last_value(id) OVER w AS last_id
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (START UP+)
    DEFINE START AS TRUE, UP AS val > PREV(val))
  ORDER BY id;
-- (val).prev는 속성 표기법이므로
-- 평범한 함수 prev(val)을 호출한다
-- (여기서는 IMMUTABLE 사용자 prev), 아래의 스키마 한정 호출과 마찬가지다
SELECT id, val, count(*) OVER w AS cnt, last_value(id) OVER w AS last_id
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+)
    DEFINE A AS (val).prev = -999)
  ORDER BY id;
SELECT id, val, count(*) OVER w AS cnt, last_value(id) OVER w AS last_id
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+)
    DEFINE A AS rpr_navns.prev(val) = -999)
  ORDER BY id;

-- 인자가 0 개이거나 2 개를 넘으면 오류이며, 함수로의 대체 처리는 없다
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV() IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(val, 1, 2) IS NULL);
-- 정확히 그 인자 개수의 사용자 함수가 있어도 오류는 유지된다
CREATE FUNCTION prev(integer, integer, integer) RETURNS integer
  AS 'SELECT -999' LANGUAGE sql IMMUTABLE;
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(val, 1, 2) IS NULL);
DROP FUNCTION prev(integer, integer, integer);

-- 구문적 장식은 거부된다
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(*) IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(DISTINCT val) IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(val ORDER BY val) IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(val) FILTER (WHERE true) IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(val) WITHIN GROUP (ORDER BY val) IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(val) OVER () IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(VARIADIC ARRAY[val]) IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS prev(x => val) IS NULL);
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS PREV(val) IGNORE NULLS IS NULL);

-- 인용해도 벗어나지 못한다: "prev"는 내비게이션이고, "PREV"는 평범한 이름이다
SELECT id, val, count(*) OVER w AS cnt
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (START UP+)
    DEFINE START AS TRUE, UP AS val > "prev"(val))
  ORDER BY id;
SELECT count(*) OVER w FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS "PREV"(val) IS NULL);

-- 뷰는 원래 상태로 왕복한다: 한정 없는 PREV는 내비게이션 함수로 남고, 한정된
-- 사용자 prev()는 스키마 한정 상태로 남아 내비게이션으로 재파싱되지 않는다
CREATE VIEW rpr_navns_nav AS
  SELECT id, count(*) OVER w AS cnt FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (START UP+) DEFINE START AS TRUE, UP AS val > PREV(val));
CREATE VIEW rpr_navns_fn AS
  SELECT id, count(*) OVER w AS cnt FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS rpr_navns.prev(val) = -999);
SELECT pg_get_viewdef('rpr_navns_nav');
SELECT pg_get_viewdef('rpr_navns_fn');
DROP VIEW rpr_navns_nav, rpr_navns_fn;

-- DEFINE 안의 한정된 last()는 디파스 시에도 스키마 한정 상태로 남아야 LAST
-- 내비게이션 함수로 재파싱되지 않는다 (강제 한정 경로)
CREATE FUNCTION rpr_navns.last(integer) RETURNS integer AS 'SELECT -999' LANGUAGE sql IMMUTABLE;
CREATE VIEW rpr_navns_fn_last AS
  SELECT id, count(*) OVER w AS cnt FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS rpr_navns.last(val) = -999);
SELECT pg_get_viewdef('rpr_navns_fn_last');
DROP VIEW rpr_navns_fn_last;
DROP FUNCTION rpr_navns.last(integer);

-- 속성 표기법은 결코 내비게이션 호출이 아니다: 필드나 평범한 함수로 풀린다
CREATE TYPE rpr_navns_pair AS (first int, last int);
CREATE TABLE rpr_composite_rows (id int, p rpr_navns_pair);
INSERT INTO rpr_composite_rows VALUES (1, (10, 20)), (2, (30, 40));
SELECT (p).last FROM rpr_composite_rows ORDER BY id;
SELECT count(*) OVER w FROM rpr_composite_rows
  WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS (p).last > 0);
SELECT count(*) OVER w FROM rpr_composite_rows
  WINDOW w AS (ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+) DEFINE A AS (p).prev > 0);

-- 내비게이션 오프셋에는 내비게이션 연산이 들어갈 수 없다
SELECT id, val
  FROM rpr_nav_rows
  WINDOW w AS (PARTITION BY g ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING INITIAL
    PATTERN (A+)
    DEFINE A AS PREV(val, FIRST(1)) > 0)
  ORDER BY id;

DROP SCHEMA rpr_navns CASCADE;
RESET search_path;

-- ============================================================
-- SKIP TO / INITIAL 테스트
-- ============================================================

CREATE TABLE rpr_skip (id INT, val INT);
INSERT INTO rpr_skip VALUES
    (1, 1), (2, 2), (3, 3), (4, 4), (5, 5),
    (6, 6), (7, 7), (8, 8);

-- SKIP TO NEXT ROW

-- SKIP TO NEXT ROW
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_skip
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B C)
    DEFINE A AS val > 0, B AS val > 2, C AS val > 4
);

-- SKIP PAST LAST ROW

-- SKIP PAST LAST ROW
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_skip
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B C)
    DEFINE A AS val > 0, B AS val > 2, C AS val > 4
);

-- 기본 동작 (SKIP PAST LAST ROW여야 한다)

-- SKIP TO 절 없음 (기본값)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_skip
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B)
    DEFINE A AS val > 0, B AS val > 1
);

-- 기본값과 명시적인 PAST LAST ROW 비교
-- 결과는 동일해야 한다
WITH default_skip AS (
    SELECT id, val, COUNT(*) OVER w as cnt
    FROM rpr_skip
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B C)
        DEFINE A AS val > 0, B AS val > 2, C AS val > 4
    )
),
explicit_skip AS (
    SELECT id, val, COUNT(*) OVER w as cnt
    FROM rpr_skip
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (A B C)
        DEFINE A AS val > 0, B AS val > 2, C AS val > 4
    )
)
SELECT 'default' as type, * FROM default_skip
UNION ALL
SELECT 'explicit' as type, * FROM explicit_skip
ORDER BY type, id;

DROP TABLE rpr_skip;

CREATE TABLE rpr_init (id INT, val INT);
INSERT INTO rpr_init VALUES (1, 10), (2, 20), (3, 30), (4, 40);

-- 명시적 INITIAL
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_init
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 암묵적 INITIAL (기본값)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_init
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

DROP TABLE rpr_init;

-- SEEK

CREATE TABLE rpr_seek (id INT, val INT);
INSERT INTO rpr_seek VALUES (1, 10);

-- SEEK 키워드는 인식되지만, SEEK 모드는 지원되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_seek
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    SEEK
    PATTERN (A+)
    DEFINE A AS val > 0
);

DROP TABLE rpr_seek;

-- PERMUTE

CREATE TABLE rpr_permute (id INT, val INT);
INSERT INTO rpr_permute VALUES (1, 10);

-- PERMUTE 구문은 인식되지만, 이 기능은 지원되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_permute
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (PERMUTE(A))
    DEFINE A AS val > 0
);

-- 목록에 대해서도, 어떤 모양의 하위 패턴에 대해서도 같은 방식으로 거부된다
SELECT COUNT(*) OVER w
FROM rpr_permute
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (PERMUTE(A+ B, C | D))
    DEFINE A AS val > 0, B AS val > 1, C AS val > 2, D AS val > 3
);

-- PERMUTE는 비예약어로 남아 있으므로 여전히 패턴 변수로 쓸 수 있다
SELECT COUNT(*) OVER w
FROM rpr_permute
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (PERMUTE A)
    DEFINE PERMUTE AS val > 5, A AS val > 0
);

-- 예외는 그룹 바로 앞에 올 때뿐이다: PERMUTE는 콤마가 뒤따르든 말든 "("에서
-- 옮겨가므로, 그런 변수는 지원되지 않는다는 오류로 떨어지고 그 사용자에게는
-- 교대를 쓰라는 조언이 핵심을 벗어난다.  힌트는 빠져나갈 방법도 함께
-- 알려줘야 한다.
SELECT COUNT(*) OVER w
FROM rpr_permute
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (PERMUTE (A | B))
    DEFINE PERMUTE AS val > 5, A AS val > 0, B AS val > 9
);

-- 인용하면 같은 쿼리가 실행된다
SELECT COUNT(*) OVER w
FROM rpr_permute
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ("permute" (A | B))
    DEFINE PERMUTE AS val > 5, A AS val > 0, B AS val > 9
);

-- 디파스는 그런 변수를 반드시 인용해야 한다.  그러지 않으면 그것을 담은 뷰가
-- PERMUTE 구문으로 재파싱될 것이다.  다른 변수들은 인용되지 않은 채로 남는다
CREATE VIEW rpr_permute_v AS
  SELECT COUNT(*) OVER w AS cnt FROM rpr_permute
  WINDOW w AS (
      ORDER BY id
      ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
      PATTERN ("permute" (A))
      DEFINE PERMUTE AS val > 5, A AS val > 0
  );
SELECT pg_get_viewdef('rpr_permute_v'::regclass);

-- 뒤에 그룹이 오지 않는 경우에도 인용된다: 디파서는 모호하게 만들 "("가 있는지
-- 미리 살피는 대신, PATTERN 안에 나타나는 곳마다 그 이름을 인용한다
CREATE VIEW rpr_permute_v2 AS
  SELECT COUNT(*) OVER w AS cnt FROM rpr_permute
  WINDOW w AS (
      ORDER BY id
      ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
      PATTERN (PERMUTE A)
      DEFINE PERMUTE AS val > 5, A AS val > 0
  );
SELECT pg_get_viewdef('rpr_permute_v2'::regclass);

-- EXPLAIN은 자체 출력기로 컴파일된 패턴을 디파스하므로, ruleutils와 같은
-- 이름을 인용해야 한다.  교대는 그룹이 평탄화되어 사라지는 것을 막는데, 이것이
-- 변수 뒤에 "("가 붙게 만드는 요인이다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w
FROM rpr_permute
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ("permute" (A | B))
    DEFINE PERMUTE AS val > 5, A AS val > 0, B AS val > 9
);

DROP VIEW rpr_permute_v, rpr_permute_v2;
DROP TABLE rpr_permute;

-- ============================================================
-- 직렬화/역직렬화 테스트
-- ============================================================
-- 여기서 명시적으로 삭제하지 않는 RPR 정의 뷰와 테이블은,
-- pg_dump/pg_upgrade 가 RPR 윈도우 절의 디파스 후 재파싱 왕복을 검증하도록
-- 일부러 남겨둔 것이다.

-- 뷰 생성과 디파스

CREATE TABLE rpr_serial (id INT, val INT);
INSERT INTO rpr_serial VALUES
    (1, 10), (2, 20), (3, 15), (4, 25), (5, 30);

-- 단순 패턴
CREATE VIEW rpr_serial_v1 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_serial
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 뷰가 동작하는지 확인 (역직렬화 테스트)
SELECT * FROM rpr_serial_v1 ORDER BY id;

-- 디파스 확인
SELECT pg_get_viewdef('rpr_serial_v1'::regclass);

-- 교대를 포함한 복합 패턴
CREATE VIEW rpr_serial_v2 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_serial
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ | B*)
    DEFINE A AS val > 20, B AS val <= 20
);

SELECT * FROM rpr_serial_v2 ORDER BY id;
SELECT pg_get_viewdef('rpr_serial_v2'::regclass);

-- 그룹화와 수량자를 가진 패턴
CREATE VIEW rpr_serial_v3 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_serial
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A B){2,5} | C*)
    DEFINE
        A AS val > 10,
        B AS val > 20,
        C AS val <= 10
);

SELECT * FROM rpr_serial_v3 ORDER BY id;
SELECT pg_get_viewdef('rpr_serial_v3'::regclass);

-- 모든 기능을 조합
CREATE VIEW rpr_serial_v4 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_serial
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    INITIAL
    PATTERN (START (MID{1,3} | ALT+) FINISH)
    DEFINE
        START AS val > 5,
        MID AS val BETWEEN 10 AND 25,
        ALT AS val > 25,
        FINISH AS val > 15
);

SELECT * FROM rpr_serial_v4 ORDER BY id;
SELECT pg_get_viewdef('rpr_serial_v4'::regclass);

-- 디파스 커버리지를 위한 추가 수량자

-- ? 수량자 (0 개 또는 1 개)
CREATE VIEW rpr_serial_v5 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_serial
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B?)
    DEFINE A AS val > 10, B AS val > 20
);

SELECT * FROM rpr_serial_v5 ORDER BY id;
SELECT pg_get_viewdef('rpr_serial_v5'::regclass);

-- {n,} 수량자 (n개 이상)
CREATE VIEW rpr_serial_v6 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_serial
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2,})
    DEFINE A AS val > 15
);

SELECT * FROM rpr_serial_v6 ORDER BY id;
SELECT pg_get_viewdef('rpr_serial_v6'::regclass);

-- {n} 수량자 (정확히 n개)
CREATE VIEW rpr_serial_v7 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_serial
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{3})
    DEFINE A AS val > 0
);

SELECT * FROM rpr_serial_v7 ORDER BY id;
SELECT pg_get_viewdef('rpr_serial_v7'::regclass);

-- 중첩된 ALT 패턴 (복합 중첩 구조의 디파스 테스트)
CREATE VIEW rpr_serial_v8 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_serial
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (((A+ B) | C) D | A B C)
    DEFINE A AS val <= 15, B AS val <= 25, C AS val <= 30, D AS val > 30
);

SELECT * FROM rpr_serial_v8 ORDER BY id;
SELECT pg_get_viewdef('rpr_serial_v8'::regclass);

-- 내비게이션 함수 직렬화: 오프셋을 가진 PREV
CREATE VIEW rpr_serial_nav1 AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE A AS TRUE, B AS val > PREV(val, 2));
SELECT pg_get_viewdef('rpr_serial_nav1'::regclass);

-- 내비게이션 함수 직렬화: FIRST와 LAST
CREATE VIEW rpr_serial_nav2 AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE A AS TRUE, B AS FIRST(val) < LAST(val, 1));
SELECT pg_get_viewdef('rpr_serial_nav2'::regclass);

-- 내비게이션 함수 직렬화: 복합 PREV(FIRST())
CREATE VIEW rpr_serial_nav3 AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE A AS TRUE, B AS PREV(FIRST(val, 1), 2) > 0);
SELECT pg_get_viewdef('rpr_serial_nav3'::regclass);

-- 내비게이션 함수 직렬화: 복합 NEXT(LAST())
CREATE VIEW rpr_serial_nav4 AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE A AS TRUE, B AS NEXT(LAST(val), 2) IS NOT NULL);
SELECT pg_get_viewdef('rpr_serial_nav4'::regclass);

-- 내비게이션 함수 직렬화: 복합 PREV(LAST())
CREATE VIEW rpr_serial_nav5 AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE A AS TRUE, B AS PREV(LAST(val, 1), 2) > 0);
SELECT pg_get_viewdef('rpr_serial_nav5'::regclass);

-- 내비게이션 함수 직렬화: 복합 NEXT(FIRST())
CREATE VIEW rpr_serial_nav6 AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE A AS TRUE, B AS NEXT(FIRST(val), 3) > 0);
SELECT pg_get_viewdef('rpr_serial_nav6'::regclass);

-- 예쁜 디파스: 내비게이션 호출은 함수처럼 보이며 여분의 괄호를 더 쓰지 않는다
CREATE VIEW rpr_nav_pretty_v AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+)
             DEFINE A AS TRUE,
                    B AS val > PREV(val) AND PREV(val) IS NOT NULL
                         AND NEXT(val) > FIRST(val)
                         AND PREV(FIRST(val)) > 0);
SELECT pg_get_viewdef('rpr_nav_pretty_v'::regclass, true);

-- ruleutils를 거친 소극적 {1}? 수량자 디파스
CREATE VIEW rpr_quant_reluctant_v AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL
             PATTERN (A{1}? B)
             DEFINE A AS val > 0, B AS val > 0);
SELECT pg_get_viewdef('rpr_quant_reluctant_v'::regclass);

-- 인용된 식별자 왕복: 대소문자가 섞인 이름은 인용이 필요하다
CREATE VIEW rpr_serial_quoted AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ("Start" "Up"+)
             DEFINE "Start" AS TRUE, "Up" AS val > PREV(val));
SELECT pg_get_viewdef('rpr_serial_quoted'::regclass);

-- 디파서가 스스로 덧붙이는 인용: permute는 비예약어이므로 저장된 규칙은 평범한
-- 이름을 담고 있고, 그것이 인용된 채로 돌아와야 한다는 것은 디파서만 알고
-- 있다. 이 뷰를 복원하는 것이 바로 그것을 증명한다.
CREATE VIEW rpr_serial_permute AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ("permute" (A | B))
             DEFINE PERMUTE AS val > 0, A AS val > 10, B AS val > 20);
SELECT pg_get_viewdef('rpr_serial_permute'::regclass);

-- 인라인 OVER 왕복: 인라인 윈도우 명세(WINDOW 별칭 없음)는 OVER (...)
-- 안에 디파스된다
CREATE VIEW rpr_serial_inline_over AS
SELECT id, val,
       count(*) OVER (ORDER BY id
                      ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                      PATTERN (A B+)
                      DEFINE A AS val > 10, B AS val > PREV(val)) AS cnt
FROM rpr_serial;
SELECT pg_get_viewdef('rpr_serial_inline_over'::regclass);

-- 다중 관계 뷰: DEFINE 열은 한정자 없이 디파스되므로, 뷰가 재파싱되려면 조인
-- 전체에서 모호하지 않아야 한다. 이 뷰는 위의 rpr_serial 뷰들처럼 그대로 남아
-- 있는데, 이것이 한정자 없는 DEFINE 열을 pg_dump 왕복 전체에
-- 통과시키는 요인이다.
CREATE TABLE rpr_serial_j (id INT, qty INT);
INSERT INTO rpr_serial_j VALUES (1, 5), (2, 7), (3, 9), (4, 11), (5, 13);

CREATE VIEW rpr_serial_join AS
SELECT s.id, count(*) OVER w AS cnt
FROM rpr_serial s JOIN rpr_serial_j j ON s.id = j.id
WINDOW w AS (ORDER BY s.id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (UP+) DEFINE UP AS val > 0);
SELECT pg_get_viewdef('rpr_serial_join'::regclass);

-- DEFINE 절은 한정자 없이 열만 이름으로 쓸 수 있으므로, 그 이름은 출력된
-- 그대로 풀려야 한다.  쿼리의 다른 관계가 그 이름의 열을 갖게 되면, 디파서는
-- 열 별칭 목록으로 새로 온 쪽을 옆으로 밀어내는데, 이는 USING으로 병합된 열을
-- 보호하는 것과 같은 방식이다.

CREATE TABLE rpr_pin (id INT, val INT);
CREATE TABLE rpr_pin_other (id INT);
INSERT INTO rpr_pin VALUES (1, 10), (2, 20), (3, 15);
INSERT INTO rpr_pin_other VALUES (1), (2), (3);

CREATE VIEW rpr_pin_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_pin, rpr_pin_other
WHERE rpr_pin.id = rpr_pin_other.id
WINDOW w AS (ORDER BY rpr_pin.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS val > 0);

-- 내비게이션 연산을 거쳐 도달하는 이름도 마찬가지로 고정된다
CREATE VIEW rpr_pin_nav_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_pin, rpr_pin_other
WHERE rpr_pin.id = rpr_pin_other.id
WINDOW w AS (ORDER BY rpr_pin.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS PREV(val) < val);

-- 아직 충돌이 없으므로 열 별칭 목록도 없다
SELECT pg_get_viewdef('rpr_pin_v'::regclass, true);

ALTER TABLE rpr_pin_other ADD COLUMN val INT;

SELECT pg_get_viewdef('rpr_pin_v'::regclass, true);
SELECT pg_get_viewdef('rpr_pin_nav_v'::regclass, true);

-- 그리고 디파스된 텍스트는 동일한 뷰를 만든다
CREATE VIEW rpr_pin_v2 AS
 SELECT count(*) OVER w AS cnt
   FROM rpr_pin,
    rpr_pin_other rpr_pin_other(id, val_1)
  WHERE rpr_pin.id = rpr_pin_other.id
  WINDOW w AS (ORDER BY rpr_pin.id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  AFTER MATCH SKIP PAST LAST ROW
  INITIAL
  PATTERN (a+)
  DEFINE
  a AS val > 0);

SELECT pg_get_viewdef('rpr_pin_v'::regclass, true)
     = pg_get_viewdef('rpr_pin_v2'::regclass, true) AS identical;

-- 이 절이 막으려는 위험 자체를 애초에 작성할 수 없다: 행 생성자를 통한 전체 행
-- 참조는 DEFINE에서 거부되므로, 그런 것을 디파서에까지 담아 오는 뷰는 있을
-- 수 없다.
CREATE VIEW rpr_pin_row_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_pin, rpr_pin_other
WHERE rpr_pin.id = rpr_pin_other.id
WINDOW w AS (ORDER BY rpr_pin.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS ROW(rpr_pin.*) IS NOT NULL);

-- USING으로 병합된 열도 같은 방식으로 고정된다
CREATE TABLE rpr_pin_l (x INT, y INT);
CREATE TABLE rpr_pin_r (x INT, z INT);
CREATE TABLE rpr_pin_x (id INT);

CREATE VIEW rpr_pin_using_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_pin_l JOIN rpr_pin_r USING (x), rpr_pin_x
WINDOW w AS (ORDER BY rpr_pin_l.y
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS x > 0);

ALTER TABLE rpr_pin_x ADD COLUMN x INT;

SELECT pg_get_viewdef('rpr_pin_using_v'::regclass, true);

-- JOIN ... ON도 마찬가지이며, 뷰는 계속 자신의 행을 반환한다
CREATE TABLE rpr_pin_j1 (id INT, price INT);
CREATE TABLE rpr_pin_j2 (id INT, qty INT);
INSERT INTO rpr_pin_j1 VALUES (1, 10), (2, 20);
INSERT INTO rpr_pin_j2 VALUES (1, 5), (2, 7);

CREATE VIEW rpr_pin_on_v AS
SELECT j1.id, count(*) OVER w AS cnt
FROM rpr_pin_j1 j1 JOIN rpr_pin_j2 j2 ON j1.id = j2.id
WINDOW w AS (ORDER BY j1.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS price > 0);

ALTER TABLE rpr_pin_j2 ADD COLUMN price INT;

SELECT pg_get_viewdef('rpr_pin_on_v'::regclass, true);
SELECT * FROM rpr_pin_on_v ORDER BY id;

-- 같은 쿼리를 새로 작성하면 거부된다.  그 이름을 고정해 주는 것이 없기
-- 때문이다.  고정이 바로 저장된 rpr_pin_on_v 정의가 계속 재파싱될 수 있게
-- 해주는 요인이다.
SELECT j1.id, count(*) OVER w AS cnt
FROM rpr_pin_j1 j1 JOIN rpr_pin_j2 j2 ON j1.id = j2.id
WINDOW w AS (ORDER BY j1.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS price > 0);

-- 별칭이 붙은 조인은 자신의 입력을 감추므로, 출력되는 이름은 varno가 담고 있는
-- 하위 열이 아니라 varnosyn에서 가져온 조인 자신의 이름이다.  하위 열을 대신
-- 고정한다면 출력에 결코 나타나지 않을 이름을 예약해 두는 셈이 되어, 출력되는
-- 이름은 나중에 오는 열과 충돌할 여지를 남기게 된다.
CREATE TABLE rpr_pin_a (i INT, x INT);
CREATE TABLE rpr_pin_b (k INT, y INT);
CREATE TABLE rpr_pin_c (m INT);
INSERT INTO rpr_pin_a VALUES (1, 10), (2, 20);
INSERT INTO rpr_pin_b VALUES (1, 5), (2, 7);
INSERT INTO rpr_pin_c VALUES (100), (200);

CREATE VIEW rpr_pin_alias_v AS
SELECT count(*) OVER w AS cnt
FROM (rpr_pin_a JOIN rpr_pin_b ON rpr_pin_a.i = rpr_pin_b.k) j(p, q, r, s),
     rpr_pin_c
WINDOW w AS (ORDER BY rpr_pin_c.m
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A)
             DEFINE A AS q > 0);

ALTER TABLE rpr_pin_c ADD COLUMN q INT;

SELECT pg_get_viewdef('rpr_pin_alias_v'::regclass, true);
SELECT * FROM rpr_pin_alias_v;

-- 그리고 디파스된 텍스트는 같은 행을 반환하는 뷰를 만든다
CREATE VIEW rpr_pin_alias_v2 AS
SELECT count(*) OVER w AS cnt
FROM (rpr_pin_a JOIN rpr_pin_b ON rpr_pin_a.i = rpr_pin_b.k) j(p, q, r, s),
     rpr_pin_c rpr_pin_c(m, q_1)
WINDOW w AS (ORDER BY rpr_pin_c.m
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW
             INITIAL
             PATTERN (a)
             DEFINE a AS q > 0);
SELECT * FROM rpr_pin_alias_v2;
DROP VIEW rpr_pin_alias_v2;

-- 사용자 열 별칭 목록이 없어도 조인은 여전히 출력된 이름을 유지하며, 옆으로
-- 밀려나는 쪽은 입력 관계다.
CREATE VIEW rpr_pin_alias_v3 AS
SELECT count(*) OVER w AS cnt
FROM (rpr_pin_a JOIN rpr_pin_b ON rpr_pin_a.i = rpr_pin_b.k) j, rpr_pin_c
WINDOW w AS (ORDER BY rpr_pin_c.m
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A)
             DEFINE A AS x > 0);
SELECT pg_get_viewdef('rpr_pin_alias_v3'::regclass, true);

DROP VIEW rpr_pin_alias_v3;
DROP VIEW rpr_pin_alias_v;
DROP TABLE rpr_pin_a, rpr_pin_b, rpr_pin_c;

-- 관계 RTE는 사용자가 작성한 열 별칭을 출력하며 카탈로그 이름을 출력하지
-- 않으므로, 예약해야 할 이름은 그 별칭이다.  카탈로그 이름을 고정한다면 출력
-- 텍스트에서 별칭을 대체하게 되고, 아무도 출력하지 않는 이름과만 충돌하는
-- 무관한 열을 옆으로 밀어내게 된다.
CREATE TABLE rpr_pin_d (i INT, k INT);
CREATE TABLE rpr_pin_e (m INT);
INSERT INTO rpr_pin_d VALUES (1, 10), (2, 20);
INSERT INTO rpr_pin_e VALUES (100), (200);

CREATE VIEW rpr_pin_rel_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_pin_d d(p, q), rpr_pin_e
WINDOW w AS (ORDER BY rpr_pin_e.m
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A)
             DEFINE A AS q > 0);

-- 카탈로그 이름을 따서 지은 열은 충돌이 아니다: 출력되는 것은 q이기 때문이다
ALTER TABLE rpr_pin_e ADD COLUMN k INT;

SELECT pg_get_viewdef('rpr_pin_rel_v'::regclass, true);

-- 별칭을 따서 지은 열은 충돌이며, 옆으로 밀려난다
ALTER TABLE rpr_pin_e ADD COLUMN q INT;

SELECT pg_get_viewdef('rpr_pin_rel_v'::regclass, true);
SELECT * FROM rpr_pin_rel_v;

DROP VIEW rpr_pin_rel_v;
DROP TABLE rpr_pin_d, rpr_pin_e;

-- DEFINE 절이 읽는 이름은 쿼리 안에서 다른 어떤 식으로도 표기할 수 없는 유일한
-- 이름이다.  한정자 자리는 패턴 변수를 위해 예약되어 있기 때문이다.
-- set_using_names()는 USING으로 병합된 모든 열의 이름을 자신보다 먼저
-- 골라내며, 어떤 이름이든 자유롭게 골라 병합된 입력의 이름을 그에 맞게 바꿀 수
-- 있다.  그래서 이미 정해진 DEFINE 이름이 먼저 예약되고, 병합된 이름은 그
-- 주위에서 골라진다.  여기서는 두 번째 USING이 원래대로라면 DEFINE 절이 읽는
-- 바로 그 열인 x_1 을 골랐을 것이다: 익명 FULL JOIN이 USING 이름을 쿼리
-- 전체에서 고유하게 만들도록 강제하는데, 이것이 평범한 x를 차지하므로 다음
-- 것은 x_1 까지 세어 올라간다.
CREATE TABLE rpr_res_t (x_1 INT, id INT);
CREATE TABLE rpr_res_l1 (x INT);
CREATE TABLE rpr_res_r1 (x INT);
CREATE TABLE rpr_res_l2 (x INT);
CREATE TABLE rpr_res_r2 (x INT);
INSERT INTO rpr_res_t VALUES (1, 1), (2, 2);
INSERT INTO rpr_res_l1 VALUES (1);
INSERT INTO rpr_res_r1 VALUES (1);
INSERT INTO rpr_res_l2 VALUES (1);
INSERT INTO rpr_res_r2 VALUES (1);

CREATE VIEW rpr_res_using_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_t,
     (rpr_res_l1 FULL JOIN rpr_res_r1 USING (x)),
     (rpr_res_l2 JOIN rpr_res_r2 USING (x))
WINDOW w AS (ORDER BY rpr_res_t.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS x_1 > 0);

SELECT pg_get_viewdef('rpr_res_using_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_using_rt AS '
       || pg_get_viewdef('rpr_res_using_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_using_v'::regclass, true)
       = pg_get_viewdef('rpr_res_using_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_using_v;
SELECT * FROM rpr_res_using_rt;

DROP VIEW rpr_res_using_rt, rpr_res_using_v;
DROP TABLE rpr_res_t, rpr_res_l1, rpr_res_r1, rpr_res_l2, rpr_res_r2;

-- 병합된 열은 자신의 고유한 이름을 유지하며 마찬가지로 충돌한다. 이 열은
-- set_relation_column_names()가 나중에 옆으로 밀어낼 수 없는 열이다: 그 이름은
-- 그 함수가 실행되기 전에 정해져 양쪽 입력에 이미 건네졌으므로, 그곳의 루프는
-- 이 열을 건너뛴다.  평범한 열이 그 자리에 있었다면 옆으로 밀려났을 것이며,
-- 그것이 위의 rpr_pin 뷰들이 다루는 경우다.
CREATE TABLE rpr_res_a (j INT, p INT);
CREATE TABLE rpr_res_b (j INT, q INT);
CREATE TABLE rpr_res_c (r INT, s INT);
INSERT INTO rpr_res_a VALUES (1, 10);
INSERT INTO rpr_res_b VALUES (1, 30);
INSERT INTO rpr_res_c VALUES (1, 10), (2, 20), (3, 15);

CREATE VIEW rpr_res_merged_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_a JOIN rpr_res_b USING (j) CROSS JOIN rpr_res_c
WINDOW w AS (ORDER BY rpr_res_c.s
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL PATTERN (X Y+)
             DEFINE X AS true, Y AS s > PREV(s));

-- 충돌은 이제야 나타난다: 병합된 열은 줄곧 j라는 이름이었다
ALTER TABLE rpr_res_c RENAME COLUMN s TO j;

SELECT pg_get_viewdef('rpr_res_merged_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_merged_rt AS '
       || pg_get_viewdef('rpr_res_merged_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_merged_v'::regclass, true)
       = pg_get_viewdef('rpr_res_merged_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_merged_v;
SELECT * FROM rpr_res_merged_rt;

DROP VIEW rpr_res_merged_rt, rpr_res_merged_v;
DROP TABLE rpr_res_a, rpr_res_b, rpr_res_c;

-- 병합된 열의 이름을 바꾸면 그것이 병합하는 열들의 이름도 바뀌며, 그 이름은
-- 이미 같은 이름의 실제 열을 가진 RTE에 떨어질 수 있다.  DEFINE 절이 읽는 열은
-- 옮길 수 없는 열이므로, 병합은 그것을 건너뛰어 세고 RTE는 서로 다른 별칭 두
-- 개를 출력한다.
CREATE TABLE rpr_res_fa (k INT);
CREATE TABLE rpr_res_fb (k INT);
CREATE TABLE rpr_res_ga (k INT, k_1 INT);
CREATE TABLE rpr_res_gb (k INT);
CREATE TABLE rpr_res_ord (id INT);
INSERT INTO rpr_res_fa VALUES (1);
INSERT INTO rpr_res_fb VALUES (1);
INSERT INTO rpr_res_ga VALUES (1, 5);
INSERT INTO rpr_res_gb VALUES (1);
INSERT INTO rpr_res_ord VALUES (1), (2);

CREATE VIEW rpr_res_dup_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_fa FULL JOIN rpr_res_fb USING (k),
     rpr_res_ga JOIN rpr_res_gb USING (k),
     rpr_res_ord
WINDOW w AS (ORDER BY rpr_res_ord.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS k_1 > 0);

SELECT pg_get_viewdef('rpr_res_dup_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_dup_rt AS '
       || pg_get_viewdef('rpr_res_dup_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_dup_v'::regclass, true)
       = pg_get_viewdef('rpr_res_dup_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_dup_v;
SELECT * FROM rpr_res_dup_rt;

DROP VIEW rpr_res_dup_rt, rpr_res_dup_v;
DROP TABLE rpr_res_fa, rpr_res_fb, rpr_res_ga, rpr_res_gb, rpr_res_ord;

-- DEFINE 절이 읽는 병합된 열은 DEFINE 절이 이름을 정한다: 그 이름은
-- set_using_names()가 실행되기 전에 정해지며, USING 절은 새로 짓는 대신 그것을
-- 그대로 받아들인다.  따라서 병합된 이름은 여기서 계속 id로 남고, 옆으로
-- 밀려나는 쪽은 새로 들어온 것이다.
CREATE TABLE rpr_res_p (id INT, v INT);
CREATE TABLE rpr_res_q (id INT, w INT);
CREATE TABLE rpr_res_s (n INT);
INSERT INTO rpr_res_p VALUES (1, 10), (2, 20);
INSERT INTO rpr_res_q VALUES (1, 30), (3, 40);
INSERT INTO rpr_res_s VALUES (7);

CREATE VIEW rpr_res_full_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_p FULL JOIN rpr_res_q USING (id), rpr_res_s
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS id > 0);

ALTER TABLE rpr_res_s ADD COLUMN id INT;

SELECT pg_get_viewdef('rpr_res_full_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_full_rt AS '
       || pg_get_viewdef('rpr_res_full_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_full_v'::regclass, true)
       = pg_get_viewdef('rpr_res_full_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_full_v;
SELECT * FROM rpr_res_full_rt;

DROP VIEW rpr_res_full_rt, rpr_res_full_v;
DROP TABLE rpr_res_p, rpr_res_q, rpr_res_s;

-- 별칭이 붙은 조인은 자신의 입력을 대신하여 책임진다.  파서는 그런 조인의 모든
-- 열에 조인 자신의 varnosyn을 부여하므로, 그 입력이 들여온 열을 읽는 DEFINE
-- 절은 원래의 관계가 아니라 조인을 이름으로 지목한다.  이름은 어차피 정해지며,
-- 조인의 USING 절이 그것을 만든 주체가 아니므로 예약된다: 자신의 USING 절이
-- 이름을 짓지 않는 조인의 열도 관계의 열과 다를 바 없이 병합된 것이다.  예약해
-- 두지 않으면 병합된 이름이 그 위로 세어 올라가고 조인은 같은 별칭을 두 번
-- 출력하는데, 이는 모호한 열로 재파싱된다.
CREATE TABLE rpr_res_ja (x INT, x_1 INT);
CREATE TABLE rpr_res_jb (x INT, z INT);
CREATE TABLE rpr_res_m1 (x INT);
CREATE TABLE rpr_res_m2 (x INT);
CREATE TABLE rpr_res_ordj (id INT);
INSERT INTO rpr_res_ja VALUES (1, 7);
INSERT INTO rpr_res_jb VALUES (1, 9);
INSERT INTO rpr_res_m1 VALUES (1);
INSERT INTO rpr_res_m2 VALUES (1);
INSERT INTO rpr_res_ordj VALUES (1), (2);

CREATE VIEW rpr_res_alias_v AS
SELECT count(*) OVER w AS cnt
FROM (rpr_res_m1 FULL JOIN rpr_res_m2 USING (x)),
     (rpr_res_ja JOIN rpr_res_jb USING (x)) AS jx,
     rpr_res_ordj
WINDOW w AS (ORDER BY rpr_res_ordj.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS x_1 > 0);

SELECT pg_get_viewdef('rpr_res_alias_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_alias_rt AS '
       || pg_get_viewdef('rpr_res_alias_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_alias_v'::regclass, true)
       = pg_get_viewdef('rpr_res_alias_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_alias_v;
SELECT * FROM rpr_res_alias_rt;


-- 쿼리 텍스트에 어떤 열 이름도 짓지 않는 NATURAL JOIN에서도 마찬가지다.  위
-- 테스트는 조인의 USING 절을 읽어 병합된 열과 그냥 통과할 뿐인 열을
-- 구별하는데, 분석된 트리에서는 그것을 그렇게 읽는다: 파서가 NATURAL이 어떤
-- 열들을 병합하는지 알아내어 그곳에 기록해 두기 때문이다.
CREATE VIEW rpr_res_nat_v AS
SELECT count(*) OVER w AS cnt
FROM (rpr_res_m1 FULL JOIN rpr_res_m2 USING (x)),
     (rpr_res_ja NATURAL JOIN rpr_res_jb) AS jx,
     rpr_res_ordj
WINDOW w AS (ORDER BY rpr_res_ordj.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS x_1 > 0);

SELECT pg_get_viewdef('rpr_res_nat_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_nat_rt AS '
       || pg_get_viewdef('rpr_res_nat_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_nat_v'::regclass, true)
       = pg_get_viewdef('rpr_res_nat_rt'::regclass, true) AS round_trips;

DROP VIEW rpr_res_nat_rt, rpr_res_nat_v;
DROP VIEW rpr_res_alias_rt, rpr_res_alias_v;
DROP TABLE rpr_res_ja, rpr_res_jb, rpr_res_m1, rpr_res_m2, rpr_res_ordj;

-- 뷰를 만든 뒤 함수의 결과 타입이 커지면서 늘어난 열은 디파서가 아예 보지
-- 못하는 열이다: expandRTE()는 쿼리가 파싱될 당시의 열 개수에서 멈춘다. 보이지
-- 않는 열은 옆으로 비켜 이름을 바꿔줄 수 없는 열이며, 여기서 그것이 충돌하는
-- 이름은 DEFINE 절이 출력된 그대로 풀어야 하는 이름이다.  그래서 늘어난 열들도
-- 찾아 이름이 지어지고, 별칭 목록이 위치 기반이므로 전체가 출력된다.
CREATE TABLE rpr_res_fn (id INT, val INT);
INSERT INTO rpr_res_fn VALUES (1, 1), (2, 2), (3, 3);
CREATE TABLE rpr_res_cfg (a INT);
INSERT INTO rpr_res_cfg VALUES (1);
CREATE FUNCTION rpr_res_fcfg() RETURNS SETOF rpr_res_cfg LANGUAGE sql
  AS $$ SELECT * FROM rpr_res_cfg $$;

CREATE VIEW rpr_res_fn_v AS
SELECT rpr_res_fn.id, count(*) OVER w AS cnt
FROM rpr_res_fn, rpr_res_fcfg() f
WINDOW w AS (ORDER BY rpr_res_fn.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS val > 0);

-- 아직 막아야 할 것이 없다
SELECT pg_get_viewdef('rpr_res_fn_v'::regclass, true);

ALTER TABLE rpr_res_cfg ADD COLUMN val INT;

SELECT pg_get_viewdef('rpr_res_fn_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_fn_rt AS '
       || pg_get_viewdef('rpr_res_fn_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_fn_v'::regclass, true)
       = pg_get_viewdef('rpr_res_fn_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_fn_v;
SELECT * FROM rpr_res_fn_rt;

-- 아무것과도 충돌하지 않는, 늘어난 열도 여전히 목록에 있다
ALTER TABLE rpr_res_cfg ADD COLUMN spare INT;
SELECT pg_get_viewdef('rpr_res_fn_v'::regclass, true);

DROP VIEW rpr_res_fn_rt, rpr_res_fn_v;
DROP FUNCTION rpr_res_fcfg();
DROP TABLE rpr_res_fn, rpr_res_cfg;

-- 시스템 열은 디파서가 스스로 고른 것이 아니라 카탈로그에서 이름이 정해지므로,
-- 그것을 위해 고를 별칭도 없고 이름 바꾸기에서 면제해 줄 것도 없다.  그 이름은
-- 여전히 쿼리의 나머지와 겹치지 않도록 지켜져야 한다.  그러지 않으면 나중에
-- 나타나는 열이 그 이름에 응답하게 된다.  함수는 호출될 당시의 타입 그대로
-- 자신의 행을 만들므로 타입이 커진 뒤에도 여전히 한 행을 반환하며, 늘어난
-- 열에는 NULL이 들어간다.  rpr_res_sys.ctid 대신 그 열을 읽는 DEFINE 절이
-- 있다면 어떤 행에도 매치되지 않을 것이다.
CREATE TABLE rpr_res_sys (id INT, v INT);
INSERT INTO rpr_res_sys VALUES (1, 1), (2, 2);
CREATE TYPE rpr_res_ct AS (a INT);
CREATE FUNCTION rpr_res_fct() RETURNS SETOF rpr_res_ct LANGUAGE sql
  AS $$ SELECT * FROM json_populate_record(NULL::rpr_res_ct, '{"a": 1}') $$;

CREATE VIEW rpr_res_sys_v AS
SELECT rpr_res_sys.id, count(*) OVER w AS cnt
FROM rpr_res_sys, rpr_res_fct() f
WINDOW w AS (ORDER BY rpr_res_sys.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS ctid IS NOT NULL);

ALTER TYPE rpr_res_ct ADD ATTRIBUTE ctid INT;

SELECT pg_get_viewdef('rpr_res_sys_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_sys_rt AS '
       || pg_get_viewdef('rpr_res_sys_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_sys_v'::regclass, true)
       = pg_get_viewdef('rpr_res_sys_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_sys_v;
SELECT * FROM rpr_res_sys_rt;

DROP VIEW rpr_res_sys_rt, rpr_res_sys_v;
DROP FUNCTION rpr_res_fct();
DROP TYPE rpr_res_ct;
DROP TABLE rpr_res_sys;

-- 같은 deparse 처리의 네 가지 모서리 경우.
--
-- INNER JOIN USING 은 COALESCE 가 아니라 왼쪽 입력의 평범한 Var 로 병합되므로,
-- DEFINE 절을 대치해 줄 병합 표현식이 없다; 그래도 그룹화가 있으면 deparser 는
-- 그것을 찾아본다.
CREATE TABLE rpr_cov_l (id INT, v INT);
CREATE TABLE rpr_cov_r (id INT, w INT);
INSERT INTO rpr_cov_l VALUES (1, 1), (2, 2), (3, 3);
INSERT INTO rpr_cov_r VALUES (1, 1), (2, 2), (3, 3);

CREATE VIEW rpr_cov_inner_v AS
SELECT id + 1 AS idp1, count(*) OVER w AS cnt
FROM rpr_cov_l JOIN rpr_cov_r USING (id)
GROUP BY id + 1
WINDOW w AS (ORDER BY id + 1
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS id + 1 > 0);

SELECT pg_get_viewdef('rpr_cov_inner_v'::regclass, true);
SELECT 'CREATE VIEW rpr_cov_inner_rt AS '
       || pg_get_viewdef('rpr_cov_inner_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_cov_inner_v'::regclass, true)
       = pg_get_viewdef('rpr_cov_inner_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_cov_inner_v ORDER BY idp1;
SELECT * FROM rpr_cov_inner_rt ORDER BY idp1;

DROP VIEW rpr_cov_inner_rt, rpr_cov_inner_v;

-- 두 변수에서 같은 시스템 컬럼을 읽는 DEFINE 절은 그 이름을 한 번만 보관한다;
-- 두 번째 참조는 이미 보관된 이름을 만난다.
CREATE VIEW rpr_cov_sys2_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_cov_l
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B)
             DEFINE A AS tableoid > 0, B AS tableoid > 0);

SELECT pg_get_viewdef('rpr_cov_sys2_v'::regclass, true);
SELECT 'CREATE VIEW rpr_cov_sys2_rt AS '
       || pg_get_viewdef('rpr_cov_sys2_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_cov_sys2_v'::regclass, true)
       = pg_get_viewdef('rpr_cov_sys2_rt'::regclass, true) AS round_trips;

DROP VIEW rpr_cov_sys2_rt, rpr_cov_sys2_v;

-- 컬럼 정의 목록이 붙은 함수는 그 목록이 컬럼 집합을 고정하므로, 뷰를 만든
-- 뒤로 컬럼이 늘어났을 수 없다.
CREATE VIEW rpr_cov_coldef_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_cov_l, json_to_record('{"a": 1}') AS j(a int)
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS a > 0);

SELECT pg_get_viewdef('rpr_cov_coldef_v'::regclass, true);
SELECT 'CREATE VIEW rpr_cov_coldef_rt AS '
       || pg_get_viewdef('rpr_cov_coldef_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_cov_coldef_v'::regclass, true)
       = pg_get_viewdef('rpr_cov_coldef_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_cov_coldef_v;
SELECT * FROM rpr_cov_coldef_rt;

DROP VIEW rpr_cov_coldef_rt, rpr_cov_coldef_v;

-- FULL JOIN USING 이 대치할 병합 표현식을 가지고 있으면 DEFINE 절의 모든 노드가
-- 종류를 가리지 않고 검사된다.  병합이 아닌 함수 호출은 그대로 두고, 오프셋
-- 없는 내비게이션은 건너뛰어야 할 빈 오프셋 인자를 가진다.
CREATE VIEW rpr_cov_merge_v AS
SELECT id, count(*) OVER w AS cnt
FROM rpr_cov_l FULL JOIN rpr_cov_r USING (id)
GROUP BY id
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS abs(id) > 0 AND PREV(id) IS NULL OR id > 1);

SELECT pg_get_viewdef('rpr_cov_merge_v'::regclass, true);
SELECT 'CREATE VIEW rpr_cov_merge_rt AS '
       || pg_get_viewdef('rpr_cov_merge_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_cov_merge_v'::regclass, true)
       = pg_get_viewdef('rpr_cov_merge_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_cov_merge_v ORDER BY id;
SELECT * FROM rpr_cov_merge_rt ORDER BY id;

DROP VIEW rpr_cov_merge_rt, rpr_cov_merge_v;
DROP TABLE rpr_cov_l, rpr_cov_r;


-- TABLEFUNC RTE는 자신의 열 이름을 그것을 만드는 절에 직접 써 넣지만, 다른
-- RTE와 마찬가지로 열 별칭 목록도 받아들이며, 그 열 중 하나의 이름 바꾸기는
-- 그곳에 출력된다.  그래서 DEFINE 절이 읽는 이름에 응답하게 된 TABLEFUNC 열도
-- 다른 어떤 열과 마찬가지로 이름이 바뀌며, DEFINE 절은 자신의 표기를
-- 그대로 유지한다.
CREATE TABLE rpr_res_tf (id INT, s INT);
INSERT INTO rpr_res_tf VALUES (1, 1), (2, 2);

CREATE VIEW rpr_res_tf_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_tf,
     JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (c1 int PATH '$')) AS jx
WINDOW w AS (ORDER BY rpr_res_tf.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS s > 0);

-- 충돌은 이제야 나타난다
ALTER TABLE rpr_res_tf RENAME COLUMN s TO c1;

SELECT pg_get_viewdef('rpr_res_tf_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_tf_rt AS '
       || pg_get_viewdef('rpr_res_tf_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_tf_v'::regclass, true)
       = pg_get_viewdef('rpr_res_tf_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_tf_v;
SELECT * FROM rpr_res_tf_rt;

DROP VIEW rpr_res_tf_rt, rpr_res_tf_v;
DROP TABLE rpr_res_tf;

-- 별칭이 붙은 조인은 자신의 입력을 대신하여 책임지고 그것들을 감추므로, 여기서
-- DEFINE 절은 조인 자신의 열 x를 읽는다.  그 이름은 쿼리 수준 전체에서
-- 예약되며, 이는 그 아래의 TABLEFUNC 열에도 미친다: 그 열은 자신의 별칭
-- 목록에서 이름이 바뀌고, 조인은 쿼리가 보는 이름을 유지하기 위해 자신의
-- 목록에 x를 출력한다.  한정 없는 참조로는 닿지 않았을 TABLEFUNC 열은 충돌하지
-- 않았을 것이지만, 예약된 이름은 그 수준의 모든 RTE에서 비워두는데, 이는
-- 전역적으로 고유한 USING 이름과 마찬가지다.
CREATE TABLE rpr_res_hid (id INT, v INT);
CREATE TABLE rpr_res_hu (m INT);
INSERT INTO rpr_res_hid VALUES (1, 1), (2, 2), (3, 3);
INSERT INTO rpr_res_hu VALUES (9);

CREATE VIEW rpr_res_hid_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_hid,
     (JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (x int PATH '$')) AS jt
      JOIN rpr_res_hu ON jt.x > 0) j
WINDOW w AS (ORDER BY rpr_res_hid.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS x > 0);

SELECT pg_get_viewdef('rpr_res_hid_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_hid_rt AS '
       || pg_get_viewdef('rpr_res_hid_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_hid_v'::regclass, true)
       = pg_get_viewdef('rpr_res_hid_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_hid_v;
SELECT * FROM rpr_res_hid_rt;

DROP VIEW rpr_res_hid_rt, rpr_res_hid_v;
DROP TABLE rpr_res_hid, rpr_res_hu;

-- 어떤 열이 DEFINE 절이 읽는 이름을 갖게 되는 것은 뷰가 만들어진 후 이름이
-- 바뀔 때뿐이며, 그때부터 둘은 출력 텍스트에서 구별되어야 한다.  DEFINE 열은
-- 먼저 정해졌으므로 자신의 표기를 유지하고, 새로 온 열은 name_N 이라는 이름을
-- 받는다 -- 같은 RTE에 있든, DEFINE 절이 그것도 읽는 다른 RTE에 있든, USING
-- 절이 병합하는 열이든, 병합되지는 않지만 USING 절의 표기를 그대로 갖고 있어
-- 디파서가 추측할 일이 아니든 마찬가지다.  새로 온 열의 새 이름을 표기하는
-- 다른 곳의 USING 절도 마찬가지로 비켜난다.
CREATE TABLE rpr_res_ren (c INT, d INT);
INSERT INTO rpr_res_ren VALUES (1, 1), (2, 2);
CREATE TABLE rpr_res_ren2 (a INT, e INT);
INSERT INTO rpr_res_ren2 VALUES (1, 0), (2, 0);
CREATE TABLE rpr_res_renl (a_1 INT);
CREATE TABLE rpr_res_renr (a_1 INT);
INSERT INTO rpr_res_renl VALUES (1);
INSERT INTO rpr_res_renr VALUES (1);
CREATE TABLE rpr_res_rs (x INT);
CREATE TABLE rpr_res_rr (x INT, y INT);
INSERT INTO rpr_res_rs VALUES (1), (2);
INSERT INTO rpr_res_rr VALUES (1, 5), (2, 6);
CREATE TABLE rpr_res_rena (id INT, a INT);
CREATE TABLE rpr_res_renb (id INT, b INT);
INSERT INTO rpr_res_rena VALUES (1, 1), (2, 2);
INSERT INTO rpr_res_renb VALUES (1, 5), (2, 0);

-- 같은 RTE에서, 그 별칭 목록이 테이블보다 짧은 경우
CREATE VIEW rpr_res_ren_v AS
SELECT x.a, x.d, count(*) OVER w AS cnt
FROM rpr_res_ren AS x(a)
WINDOW w AS (ORDER BY x.a
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (P Q*)
             DEFINE P AS a > 0, Q AS d > 0);

-- USING 절이 병합하는 열
CREATE VIEW rpr_res_renu_v AS
SELECT a, x.d, count(*) OVER w AS cnt
FROM rpr_res_ren AS x(a) JOIN rpr_res_ren2 USING (a)
WINDOW w AS (ORDER BY a
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (P Q*)
             DEFINE P AS d > 0);

-- 새로 온 열이 받게 될 이름을 다른 곳의 USING 절이 표기하는 경우
CREATE VIEW rpr_res_renx_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_ren AS x(a), rpr_res_renl JOIN rpr_res_renr USING (a_1)
WINDOW w AS (ORDER BY x.a
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (P Q*)
             DEFINE P AS a > 0, Q AS d > 0);

-- 이름이 바뀌어 옮겨간 병합된 열과, USING 절의 표기로 이름이 바뀐 DEFINE 열
CREATE VIEW rpr_res_renm_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_rs JOIN rpr_res_rr USING (x)
WINDOW w AS (ORDER BY y
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS y > 0);

-- 다른 RTE, 그 두 열 모두 DEFINE 절이 읽는 경우
CREATE VIEW rpr_res_reno_v AS
SELECT rpr_res_rena.id, count(*) OVER w AS cnt
FROM rpr_res_rena JOIN rpr_res_renb ON rpr_res_rena.id = rpr_res_renb.id
WINDOW w AS (ORDER BY rpr_res_rena.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (P Q*)
             DEFINE P AS a > 0, Q AS b > 0);

-- 충돌은 이제야 나타난다
ALTER TABLE rpr_res_ren RENAME d TO a;
ALTER TABLE rpr_res_rr RENAME x TO z;
ALTER TABLE rpr_res_rr RENAME y TO x;
ALTER TABLE rpr_res_renb RENAME b TO a;

SELECT pg_get_viewdef('rpr_res_ren_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_ren_rt AS '
       || pg_get_viewdef('rpr_res_ren_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_ren_v'::regclass, true)
       = pg_get_viewdef('rpr_res_ren_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_ren_v;
SELECT * FROM rpr_res_ren_rt;

SELECT pg_get_viewdef('rpr_res_renu_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_renu_rt AS '
       || pg_get_viewdef('rpr_res_renu_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_renu_v'::regclass, true)
       = pg_get_viewdef('rpr_res_renu_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_renu_v;
SELECT * FROM rpr_res_renu_rt;

SELECT pg_get_viewdef('rpr_res_renx_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_renx_rt AS '
       || pg_get_viewdef('rpr_res_renx_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_renx_v'::regclass, true)
       = pg_get_viewdef('rpr_res_renx_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_renx_v;
SELECT * FROM rpr_res_renx_rt;

SELECT pg_get_viewdef('rpr_res_renm_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_renm_rt AS '
       || pg_get_viewdef('rpr_res_renm_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_renm_v'::regclass, true)
       = pg_get_viewdef('rpr_res_renm_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_renm_v;
SELECT * FROM rpr_res_renm_rt;

SELECT pg_get_viewdef('rpr_res_reno_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_reno_rt AS '
       || pg_get_viewdef('rpr_res_reno_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_reno_v'::regclass, true)
       = pg_get_viewdef('rpr_res_reno_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_reno_v;
SELECT * FROM rpr_res_reno_rt;

DROP VIEW rpr_res_reno_rt, rpr_res_reno_v;
DROP VIEW rpr_res_renm_rt, rpr_res_renm_v;
DROP VIEW rpr_res_renx_rt, rpr_res_renx_v;
DROP VIEW rpr_res_renu_rt, rpr_res_renu_v;
DROP VIEW rpr_res_ren_rt, rpr_res_ren_v;
DROP TABLE rpr_res_ren, rpr_res_ren2, rpr_res_renl, rpr_res_renr;
DROP TABLE rpr_res_rs, rpr_res_rr;
DROP TABLE rpr_res_rena, rpr_res_renb;

-- 별칭이 붙은 조인이 담고 있는 병합된 열은 처음부터 DEFINE 이름을 표기할 수
-- 있으며, 조인의 입력 중에 TABLEFUNC가 있어도 달라지는 것은 없다: 조인 자신의
-- 별칭 목록이 병합된 열의 이름을 정하고, 입력들은 그에 응답하며, DEFINE 열은
-- 그대로 둔다.  FROM 목록의 순서도 문제가 되지 않는다.
CREATE TABLE rpr_res_tj (id INT, c1 INT);
INSERT INTO rpr_res_tj VALUES (1, 1), (2, 2);
CREATE TABLE rpr_res_tb (c1 INT, y INT);
INSERT INTO rpr_res_tb VALUES (1, 10), (2, 20);
CREATE TABLE rpr_res_ti (id INT);
INSERT INTO rpr_res_ti VALUES (1), (2);

CREATE VIEW rpr_res_tj_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_tj,
     (JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (c1 int PATH '$')) AS jt
      JOIN rpr_res_tb USING (c1)) AS j(k, m)
WINDOW w AS (ORDER BY rpr_res_tj.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS c1 > 0);

CREATE VIEW rpr_res_tjr_v AS
SELECT count(*) OVER w AS cnt
FROM (JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (c1 int PATH '$')) AS jt
      JOIN rpr_res_tb USING (c1)) AS j(k, m),
     rpr_res_tj
WINDOW w AS (ORDER BY rpr_res_tj.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS c1 > 0);

-- 조인의 별칭 목록이 자신이 병합하지 않는 열에 USING 표기를 부여하며, 그 열이
-- 바로 DEFINE 절이 읽는 열이다
CREATE VIEW rpr_res_tja_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_ti,
     (JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (c1 int PATH '$')) AS jt
      JOIN rpr_res_tb USING (c1)) AS j(k, c1)
WINDOW w AS (ORDER BY rpr_res_ti.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS c1 > 0);

-- TABLEFUNC가 오른쪽에 있어도 마찬가지다
CREATE VIEW rpr_res_tjb_v AS
SELECT count(*) OVER w AS cnt
FROM (rpr_res_tb JOIN JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (c1 int PATH '$')) AS jt
      USING (c1)) AS j(a, c1)
WINDOW w AS (ORDER BY j.a
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS c1 > 0);

SELECT pg_get_viewdef('rpr_res_tj_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_tj_rt AS '
       || pg_get_viewdef('rpr_res_tj_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_tj_v'::regclass, true)
       = pg_get_viewdef('rpr_res_tj_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_tj_v;
SELECT * FROM rpr_res_tj_rt;

SELECT pg_get_viewdef('rpr_res_tjr_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_tjr_rt AS '
       || pg_get_viewdef('rpr_res_tjr_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_tjr_v'::regclass, true)
       = pg_get_viewdef('rpr_res_tjr_rt'::regclass, true) AS round_trips;

SELECT pg_get_viewdef('rpr_res_tja_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_tja_rt AS '
       || pg_get_viewdef('rpr_res_tja_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_tja_v'::regclass, true)
       = pg_get_viewdef('rpr_res_tja_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_tja_v;
SELECT * FROM rpr_res_tja_rt;

SELECT pg_get_viewdef('rpr_res_tjb_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_tjb_rt AS '
       || pg_get_viewdef('rpr_res_tjb_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_tjb_v'::regclass, true)
       = pg_get_viewdef('rpr_res_tjb_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_tjb_v;
SELECT * FROM rpr_res_tjb_rt;

DROP VIEW rpr_res_tjb_rt, rpr_res_tjb_v;
DROP VIEW rpr_res_tja_rt, rpr_res_tja_v;
DROP VIEW rpr_res_tjr_rt, rpr_res_tjr_v;
DROP VIEW rpr_res_tj_rt, rpr_res_tj_v;
DROP TABLE rpr_res_tj, rpr_res_tb, rpr_res_ti;

-- 별칭이 붙은 조인에 대해 USING 절에 주어지는 이름은 조인의 별칭 목록이 이미
-- 갖고 있는 이름들과, 그중 DEFINE 절이 읽는 이름을 모두 피해야 한다.  익명
-- FULL JOIN이 평범한 표기를 먼저 차지하므로, 두 번째 USING은 둘 다를
-- 지나쳐야 한다.
CREATE TABLE rpr_res_fa (x INT);
CREATE TABLE rpr_res_fb (x INT);
CREATE TABLE rpr_res_fc (x INT, y INT);
INSERT INTO rpr_res_fa VALUES (1);
INSERT INTO rpr_res_fb VALUES (1);
INSERT INTO rpr_res_fc VALUES (1, 3);

CREATE VIEW rpr_res_fa_v AS
SELECT count(*) OVER w AS cnt
FROM (rpr_res_fa FULL JOIN rpr_res_fb USING (x)),
     ((rpr_res_fc JOIN rpr_res_fa t4 USING (x)) AS j(x, x_1)
      JOIN rpr_res_fb t5 USING (x))
WINDOW w AS (ORDER BY j.x
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS x_1 > 0);

SELECT pg_get_viewdef('rpr_res_fa_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_fa_rt AS '
       || pg_get_viewdef('rpr_res_fa_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_fa_v'::regclass, true)
       = pg_get_viewdef('rpr_res_fa_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_fa_v;
SELECT * FROM rpr_res_fa_rt;

DROP VIEW rpr_res_fa_rt, rpr_res_fa_v;
DROP TABLE rpr_res_fa, rpr_res_fb, rpr_res_fc;

-- 별칭이 붙은 조인을 거쳐 병합되거나 자신의 열 별칭 목록을 가진 TABLEFUNC도
-- 다를 바 없다: 관계 열의 이름이 TABLEFUNC의 이름으로 바뀌면 옮겨가는 쪽은
-- TABLEFUNC 열이며, 이미 그 옮겨갈 이름을 표기하고 있는 세 번째 RTE는 그대로
-- 둔다.  그 이름은 어디서도 한정 없이 읽히지 않기 때문이다.
CREATE TABLE rpr_res_tk (id INT, y INT);
INSERT INTO rpr_res_tk VALUES (1, 1), (2, 2);
CREATE TABLE rpr_res_th (x INT, z INT);
INSERT INTO rpr_res_th VALUES (1, 1), (2, 2);
CREATE TABLE rpr_res_ta (id INT, c1 INT);
INSERT INTO rpr_res_ta VALUES (1, 1), (2, 2);
CREATE TABLE rpr_res_ts (id INT, s INT);
INSERT INTO rpr_res_ts VALUES (1, 1), (2, 2);
CREATE TABLE rpr_res_to (c1_1 INT);
INSERT INTO rpr_res_to VALUES (9);

CREATE VIEW rpr_res_tk_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_tk,
     (JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (x int PATH '$')) AS jt
      JOIN rpr_res_th USING (x)) j
WINDOW w AS (ORDER BY rpr_res_tk.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS y > 0);

CREATE VIEW rpr_res_ta_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_ta,
     JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (c1 int PATH '$')) AS jx(a)
WINDOW w AS (ORDER BY rpr_res_ta.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS c1 > 0);

CREATE VIEW rpr_res_ts_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_ts, rpr_res_to,
     JSON_TABLE(jsonb '[1,2]', '$[*]' COLUMNS (c1 int PATH '$')) AS jx
WINDOW w AS (ORDER BY rpr_res_ts.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS s > 0);

ALTER TABLE rpr_res_tk RENAME y TO x;
ALTER TABLE rpr_res_ts RENAME s TO c1;

SELECT pg_get_viewdef('rpr_res_tk_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_tk_rt AS '
       || pg_get_viewdef('rpr_res_tk_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_tk_v'::regclass, true)
       = pg_get_viewdef('rpr_res_tk_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_tk_v;
SELECT * FROM rpr_res_tk_rt;

SELECT pg_get_viewdef('rpr_res_ta_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_ta_rt AS '
       || pg_get_viewdef('rpr_res_ta_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_ta_v'::regclass, true)
       = pg_get_viewdef('rpr_res_ta_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_ta_v;
SELECT * FROM rpr_res_ta_rt;

SELECT pg_get_viewdef('rpr_res_ts_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_ts_rt AS '
       || pg_get_viewdef('rpr_res_ts_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_ts_v'::regclass, true)
       = pg_get_viewdef('rpr_res_ts_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_ts_v;
SELECT * FROM rpr_res_ts_rt;

DROP VIEW rpr_res_ts_rt, rpr_res_ts_v;
DROP VIEW rpr_res_ta_rt, rpr_res_ta_v;
DROP VIEW rpr_res_tk_rt, rpr_res_tk_v;
DROP TABLE rpr_res_tk, rpr_res_th, rpr_res_ta, rpr_res_ts, rpr_res_to;

-- DEFINE 절이 읽는 병합된 열은 USING 절이 아니라 DEFINE 절이 이름을 정한다:
-- 그것을 위해 정해진 이름을 병합이 그대로 받아들인다.  그래서 병합된 열의
-- 이름을 바꾸는 조인은 DEFINE 절이 있든 없든 같은 텍스트를 출력하며, 조인 두
-- 단계 아래의 병합도 참조가 풀리는 입력을 거쳐 도달된다.  나중에 다른 곳에서
-- 같은 이름으로 나타나는 열이 옮겨가는 쪽이다.
CREATE TABLE rpr_res_ma (x INT, y INT);
CREATE TABLE rpr_res_mb (x INT, z INT);
CREATE TABLE rpr_res_mc (x INT, r INT);
CREATE TABLE rpr_res_mo (xx INT);
INSERT INTO rpr_res_ma VALUES (1, 1), (2, 2);
INSERT INTO rpr_res_mb VALUES (1, 1), (2, 2);
INSERT INTO rpr_res_mc VALUES (1, 1), (2, 2);
INSERT INTO rpr_res_mo VALUES (1);

CREATE VIEW rpr_res_ma_v AS
SELECT count(*) OVER w AS cnt
FROM (rpr_res_ma JOIN rpr_res_mb USING (x)) AS j(x1, y, z)
WINDOW w AS (ORDER BY j.y
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS x1 > 0);

CREATE VIEW rpr_res_ma_nodef AS
SELECT count(*) OVER w AS cnt
FROM (rpr_res_ma JOIN rpr_res_mb USING (x)) AS j(x1, y, z)
WINDOW w AS (ORDER BY j.y
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING);

CREATE VIEW rpr_res_mm_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_res_mo, (rpr_res_ma JOIN rpr_res_mb USING (x)) JOIN rpr_res_mc USING (x)
WINDOW w AS (ORDER BY rpr_res_ma.y
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS x > 0);

SELECT pg_get_viewdef('rpr_res_ma_v'::regclass, true);
SELECT pg_get_viewdef('rpr_res_ma_nodef'::regclass, true);
SELECT 'CREATE VIEW rpr_res_ma_rt AS '
       || pg_get_viewdef('rpr_res_ma_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_ma_v'::regclass, true)
       = pg_get_viewdef('rpr_res_ma_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_ma_v;
SELECT * FROM rpr_res_ma_rt;

SELECT pg_get_viewdef('rpr_res_mm_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_mm_rt AS '
       || pg_get_viewdef('rpr_res_mm_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_mm_v'::regclass, true)
       = pg_get_viewdef('rpr_res_mm_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_mm_v;
SELECT * FROM rpr_res_mm_rt;

-- 그 이름은 이제야 다른 곳에서 나타난다
DROP VIEW rpr_res_mm_rt;
ALTER TABLE rpr_res_mo RENAME xx TO x;

SELECT pg_get_viewdef('rpr_res_mm_v'::regclass, true);
SELECT 'CREATE VIEW rpr_res_mm_rt AS '
       || pg_get_viewdef('rpr_res_mm_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_res_mm_v'::regclass, true)
       = pg_get_viewdef('rpr_res_mm_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_res_mm_v;
SELECT * FROM rpr_res_mm_rt;

DROP VIEW rpr_res_mm_rt, rpr_res_mm_v;
DROP VIEW rpr_res_ma_rt, rpr_res_ma_nodef, rpr_res_ma_v;
DROP TABLE rpr_res_ma, rpr_res_mb, rpr_res_mc, rpr_res_mo;

-- DEFINE 절이 그룹화 단계를 읽는 쿼리를 디파스하면 그 절의 GROUP Var들이
-- 그룹화 표현식으로 펼쳐지며, FULL JOIN USING으로 병합된 열에서는 파서가 그
-- 병합을 위해 만든 COALESCE로 펼쳐진다.  출력해 보면 양쪽 모두 같은 표기로
-- 나온다 -- DEFINE 절은 한정자를 갖지 않으므로 -- 그래서 COALESCE(id, id)는
-- 어느 쪽이 어디서 왔는지 아무것도 말해 주지 않으며, 재파싱하면 병합된 열
-- 하나가 다른 병합된 열 안에 중첩된다.  조인 RTE는 여전히 자신이 만든 것을
-- 유지하므로, 펼쳐진 결과는 다시 병합된 열 자체로 접혀 들어간다.
CREATE TABLE rpr_cds_l (id INT PRIMARY KEY, val INT);
CREATE TABLE rpr_cds_r (id INT, val INT);
CREATE TABLE rpr_cds_o (k INT);
INSERT INTO rpr_cds_l VALUES (1, 1), (2, 2);
INSERT INTO rpr_cds_r VALUES (1, 1), (3, 3);
INSERT INTO rpr_cds_o VALUES (1), (2);

CREATE VIEW rpr_cds_v AS
SELECT COALESCE(rpr_cds_l.id, rpr_cds_r.id) + 1 AS idp1, count(*) OVER w AS cnt
FROM rpr_cds_l FULL JOIN rpr_cds_r USING (id)
GROUP BY COALESCE(rpr_cds_l.id, rpr_cds_r.id) + 1
WINDOW w AS (ORDER BY COALESCE(rpr_cds_l.id, rpr_cds_r.id) + 1
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS id + 1 > 0);

SELECT pg_get_viewdef('rpr_cds_v'::regclass, true);
SELECT 'CREATE VIEW rpr_cds_rt AS '
       || pg_get_viewdef('rpr_cds_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_cds_v'::regclass, true)
       = pg_get_viewdef('rpr_cds_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_cds_v ORDER BY idp1;
SELECT * FROM rpr_cds_rt ORDER BY idp1;

-- 병합 위쪽의 외부 조인은 그룹화 표현식이 담은 사본에는 표시를 남기지만 조인
-- RTE가 유지하는 사본에는 남기지 않는다.  어느 표시도 출력 텍스트에는 나타나지
-- 않으므로, 둘은 여전히 같은 열 하나를 가리킨다.
CREATE VIEW rpr_cds_null_v AS
SELECT COALESCE(l.id, r.id) + 1 AS idp1, count(*) OVER w AS cnt
FROM rpr_cds_o LEFT JOIN (rpr_cds_l l FULL JOIN rpr_cds_r r USING (id)) ON true
GROUP BY COALESCE(l.id, r.id) + 1
WINDOW w AS (ORDER BY COALESCE(l.id, r.id) + 1
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS id + 1 > 0);

SELECT pg_get_viewdef('rpr_cds_null_v'::regclass, true);
SELECT 'CREATE VIEW rpr_cds_null_rt AS '
       || pg_get_viewdef('rpr_cds_null_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_cds_null_v'::regclass, true)
       = pg_get_viewdef('rpr_cds_null_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_cds_null_v ORDER BY idp1;
SELECT * FROM rpr_cds_null_rt ORDER BY idp1;

-- 아무것도 null로 만들지 않는 조인 아래의 같은 중첩에서는 두 사본 모두 표시가
-- 없으며, 여전히 같은 열 하나를 가리킨다.
CREATE VIEW rpr_cds_inner_v AS
SELECT COALESCE(l.id, r.id) + 1 AS idp1, count(*) OVER w AS cnt
FROM (rpr_cds_l l FULL JOIN rpr_cds_r r USING (id)) JOIN rpr_cds_o ON true
GROUP BY COALESCE(l.id, r.id) + 1
WINDOW w AS (ORDER BY COALESCE(l.id, r.id) + 1
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS id + 1 > 0);

SELECT pg_get_viewdef('rpr_cds_inner_v'::regclass, true);
SELECT 'CREATE VIEW rpr_cds_inner_rt AS '
       || pg_get_viewdef('rpr_cds_inner_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_cds_inner_v'::regclass, true)
       = pg_get_viewdef('rpr_cds_inner_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_cds_inner_v ORDER BY idp1;
SELECT * FROM rpr_cds_inner_rt ORDER BY idp1;

-- FULL JOIN USING 위에 또 다른 FULL JOIN USING을 쌓은 병합 -- 은 COALESCE 위에
-- 또 다른 COALESCE로 펼쳐진다.  안쪽 것이 먼저 접히므로 바깥쪽 것은 온전한
-- 상태로 보이고 이어서 접히며, 안에서 밖으로 접혔으므로 중첩이 두 배가 되지
-- 않고 자기 자신으로 재파싱된다.
CREATE VIEW rpr_cds_nest_v AS
SELECT count(*) OVER w AS cnt
FROM (rpr_cds_l FULL JOIN rpr_cds_r USING (id)) FULL JOIN rpr_cds_r t USING (id)
GROUP BY rpr_cds_l.id, rpr_cds_r.id, t.id
WINDOW w AS (ORDER BY rpr_cds_l.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+)
             DEFINE A AS id > 0);

SELECT pg_get_viewdef('rpr_cds_nest_v'::regclass, true);
SELECT 'CREATE VIEW rpr_cds_nest_rt AS '
       || pg_get_viewdef('rpr_cds_nest_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_cds_nest_v'::regclass, true)
       = pg_get_viewdef('rpr_cds_nest_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_cds_nest_v;
SELECT * FROM rpr_cds_nest_rt;

DROP VIEW rpr_cds_nest_rt, rpr_cds_nest_v;
DROP VIEW rpr_cds_inner_rt, rpr_cds_inner_v;
DROP VIEW rpr_cds_null_rt, rpr_cds_null_v;
DROP VIEW rpr_cds_rt, rpr_cds_v;
DROP TABLE rpr_cds_l, rpr_cds_r, rpr_cds_o;

-- 규칙은 자신의 액션 쿼리 모양이 어떻든 varprefix를 켠 채로 디파스되며, 레인지
-- 테이블은 항상 *OLD*와 *NEW*를 담고 있으므로, 그 안의 DEFINE 절은 파서가 딱
-- 잘라 거부하는 한정자를 붙인 채로 출력될 것이다.  get_rule_define()이 그 절에
-- 대해서만 접두어를 끄며, 그것이 없다면 행 패턴 쿼리를 담은 규칙은 전혀 복원될
-- 수 없다 -- 단일 테이블짜리 규칙조차도 그렇다.  바로 그 점이 이를 뷰의 경우와
-- 다른, 독자적인 사례로 만든다.
CREATE TABLE rpr_rule_t (id INT, val INT);
CREATE TABLE rpr_rule_log (id INT, cnt BIGINT);

CREATE RULE rpr_rule_r AS ON INSERT TO rpr_rule_t DO ALSO
  INSERT INTO rpr_rule_log
    SELECT id, count(*) OVER w FROM rpr_rule_t
    WINDOW w AS (ORDER BY id
                 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                 PATTERN (A+)
                 DEFINE A AS val > 0);

SELECT pg_get_ruledef(oid, true) FROM pg_rewrite WHERE rulename = 'rpr_rule_r';

-- 그리고 그 텍스트가 재파싱되어야 하는 대상이다
CREATE TABLE rpr_rule_saved AS
  SELECT pg_get_ruledef(oid, true) AS def
    FROM pg_rewrite WHERE rulename = 'rpr_rule_r';
DROP RULE rpr_rule_r ON rpr_rule_t;
SELECT def FROM rpr_rule_saved \gexec
SELECT (SELECT def FROM rpr_rule_saved) = pg_get_ruledef(oid, true) AS round_trips
  FROM pg_rewrite WHERE rulename = 'rpr_rule_r';

-- 복원된 규칙은 여전히 작동한다.  규칙 액션은 테이블뿐 아니라 문이 공급하는
-- 행에 대해서도 실행되므로, 두 행짜리 INSERT는 윈도우에 서로 다른 id 두 개로
-- 정렬할 네 행을 준다.  id가 같은 쌍끼리는 순서를 바꿔도 되므로 결과를 두 열
-- 모두에 대해 정렬한다.
INSERT INTO rpr_rule_t VALUES (1, 1), (2, 2);
SELECT * FROM rpr_rule_log ORDER BY id, cnt;

DROP TABLE rpr_rule_saved;
DROP TABLE rpr_rule_t, rpr_rule_log;

-- 마침 패턴 변수를 표기하게 되는 관계 별칭이 접두어가 잘못되는 또 다른 경로다.
-- up.price로 출력되면 그것은 단순히 거부되는 범위 변수 한정자로 돌아오는 것이
-- 아니라, 다른 규칙에 의해 다른 메시지로 거부되는 패턴 변수 한정자로 돌아온다.
-- 접두어를 켜는 것은 RTE가 둘일 때다.
CREATE TABLE rpr_pvar_a (id INT, price INT);
CREATE TABLE rpr_pvar_b (id INT);
INSERT INTO rpr_pvar_a VALUES (1, 10), (2, 20), (3, 5);
INSERT INTO rpr_pvar_b VALUES (1), (2), (3);

CREATE VIEW rpr_pvar_v AS
SELECT count(*) OVER w AS cnt
FROM rpr_pvar_a up, rpr_pvar_b
WHERE up.id = rpr_pvar_b.id
WINDOW w AS (ORDER BY up.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (up+)
             DEFINE up AS price > 0);

SELECT pg_get_viewdef('rpr_pvar_v'::regclass, true);
SELECT 'CREATE VIEW rpr_pvar_rt AS '
       || pg_get_viewdef('rpr_pvar_v'::regclass, true) \gexec
SELECT pg_get_viewdef('rpr_pvar_v'::regclass, true)
       = pg_get_viewdef('rpr_pvar_rt'::regclass, true) AS round_trips;
SELECT * FROM rpr_pvar_v;
SELECT * FROM rpr_pvar_rt;

DROP VIEW rpr_pvar_rt, rpr_pvar_v;
DROP TABLE rpr_pvar_a, rpr_pvar_b;


-- 구체화된 뷰 (지원되는 경우)

CREATE TABLE rpr_mview (id INT, val INT);
INSERT INTO rpr_mview VALUES (1, 10), (2, 20), (3, 30);

CREATE MATERIALIZED VIEW rpr_mview_v1 AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_mview
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

SELECT * FROM rpr_mview_v1 ORDER BY id;
SELECT pg_get_viewdef('rpr_mview_v1'::regclass);

-- 새로 고침 테스트
REFRESH MATERIALIZED VIEW rpr_mview_v1;
SELECT * FROM rpr_mview_v1 ORDER BY id;

-- RPR을 사용하는 CREATE TABLE AS SELECT
CREATE TABLE rpr_ctas (id INT, val INT);
INSERT INTO rpr_ctas VALUES (1, 10), (2, 20), (3, 15), (4, 25);

CREATE TABLE rpr_ctas_result AS
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_ctas
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS val > PREV(val)
);
SELECT * FROM rpr_ctas_result ORDER BY id;

-- RPR을 사용하는 INSERT INTO ... SELECT
CREATE TABLE rpr_insert_target (id INT, val INT, cnt BIGINT);
INSERT INTO rpr_insert_target
SELECT id, val, count(*) OVER w
FROM rpr_ctas
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS val > PREV(val)
);
SELECT * FROM rpr_insert_target ORDER BY id;

DROP TABLE rpr_ctas_result;
DROP TABLE rpr_insert_target;
DROP TABLE rpr_ctas;

-- 준비된 문 (플랜 캐시를 거쳐 copyfuncs.c를 테스트)

CREATE TABLE rpr_prep (id INT, val INT);
INSERT INTO rpr_prep VALUES (1, 10), (2, 20), (3, 30);

-- 단순한 준비된 문
PREPARE rpr_prep_simple AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_prep
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

EXECUTE rpr_prep_simple;
EXECUTE rpr_prep_simple;

DEALLOCATE rpr_prep_simple;

-- 매개변수를 가진 준비된 문
PREPARE rpr_prep_param(int) AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_prep
WHERE id <= $1
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 10
);

EXECUTE rpr_prep_param(2);
EXECUTE rpr_prep_param(3);

DEALLOCATE rpr_prep_param;

-- 복합 준비된 문
PREPARE rpr_prep_complex AS
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_prep
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN ((A B){1,2} | C+)
    DEFINE
        A AS val > 5,
        B AS val > 15,
        C AS val <= 15
);

EXECUTE rpr_prep_complex;
EXECUTE rpr_prep_complex;

DEALLOCATE rpr_prep_complex;

DROP TABLE rpr_prep;

-- CTE와 서브쿼리 (copyfuncs.c 테스트)

CREATE TABLE rpr_copy (id INT, val INT);
INSERT INTO rpr_copy VALUES (1, 10), (2, 20), (3, 30), (4, 40);

-- 단순 CTE
WITH rpr_cte AS (
    SELECT id, val, COUNT(*) OVER w as cnt
    FROM rpr_copy
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
)
SELECT * FROM rpr_cte ORDER BY id;

-- 여러 번 참조되는 CTE (인라인화되지 않고 CTE 스캔으로 계획됨)
WITH rpr_cte AS (
    SELECT id, val, COUNT(*) OVER w as cnt
    FROM rpr_copy
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 15
    )
)
SELECT c1.id, c1.cnt as cnt1, c2.cnt as cnt2
FROM rpr_cte c1
JOIN rpr_cte c2 ON c1.id = c2.id
ORDER BY c1.id;

-- FROM절 안의 서브쿼리
SELECT *
FROM (
    SELECT id, val, COUNT(*) OVER w as cnt
    FROM rpr_copy
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A B?)
        DEFINE A AS val > 10, B AS val > 20
    )
) sub
WHERE cnt > 0;

-- 중첩된 서브쿼리
SELECT *
FROM (
    SELECT *
    FROM (
        SELECT id, val, COUNT(*) OVER w as cnt
        FROM rpr_copy
        WINDOW w AS (
            ORDER BY id
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
            PATTERN (A+)
            DEFINE A AS val >= 10
        )
    ) inner_sub
    WHERE cnt > 0
) outer_sub;

DROP TABLE rpr_copy;

-- DISTINCT와 집합 연산 (equalfuncs.c 테스트)

CREATE TABLE rpr_equal (id INT, val INT);
INSERT INTO rpr_equal VALUES (1, 10), (2, 20), (3, 10), (4, 20);

-- RPR과 함께 쓰는 DISTINCT
SELECT DISTINCT cnt
FROM (
    SELECT id, val, COUNT(*) OVER w as cnt
    FROM rpr_equal
    WINDOW w AS (
        ORDER BY val
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP TO NEXT ROW
        PATTERN (A+)
        DEFINE A AS val > 0
    )
) sub
ORDER BY cnt;

-- 양쪽 모두 RPR을 쓰는 UNION
SELECT id, val, cnt FROM (
    SELECT id, val, COUNT(*) OVER w as cnt
    FROM rpr_equal
    WHERE val = 10
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
) sub1
UNION
SELECT id, val, cnt FROM (
    SELECT id, val, COUNT(*) OVER w as cnt
    FROM rpr_equal
    WHERE val = 20
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
) sub2
ORDER BY id;

-- UNION ALL
SELECT id, cnt FROM (
    SELECT id, COUNT(*) OVER w as cnt
    FROM rpr_equal
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 10
    )
) sub
UNION ALL
SELECT id, cnt FROM (
    SELECT id, COUNT(*) OVER w as cnt
    FROM rpr_equal
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (B+)
        DEFINE B AS val <= 10
    )
) sub
ORDER BY id, cnt;

-- INTERSECT
SELECT id, cnt FROM (
    SELECT id, COUNT(*) OVER w as cnt
    FROM rpr_equal
    WHERE id <= 3
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
) sub1
INTERSECT
SELECT id, cnt FROM (
    SELECT id, COUNT(*) OVER w as cnt
    FROM rpr_equal
    WHERE id >= 2
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
) sub2
ORDER BY id;

DROP TABLE rpr_equal;

-- 여러 윈도우 정의를 가진 뷰

CREATE TABLE rpr_multiwin (id INT, val INT);
INSERT INTO rpr_multiwin VALUES (1, 10), (2, 20), (3, 30);

CREATE VIEW rpr_multiwin_v AS
SELECT
    id,
    val,
    COUNT(*) OVER w1 as cnt1,
    COUNT(*) OVER w2 as cnt2
FROM rpr_multiwin
WINDOW
    w1 AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 15
    ),
    w2 AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (B*)
        DEFINE B AS val <= 15
    );

SELECT * FROM rpr_multiwin_v ORDER BY id;
SELECT pg_get_viewdef('rpr_multiwin_v'::regclass);

-- 뷰에서의 {n} 수량자 표시
CREATE VIEW rpr_quant_n_v AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL
             PATTERN (A{3})
             DEFINE A AS val > 0);
SELECT pg_get_viewdef('rpr_quant_n_v'::regclass);

-- 뷰에서의 {n,} 수량자 표시
CREATE VIEW rpr_quant_n_plus_v AS
SELECT id, val, count(*) OVER w
FROM rpr_serial
WINDOW w AS (ORDER BY id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL
             PATTERN (A{2,})
             DEFINE A AS val > 0);
SELECT pg_get_viewdef('rpr_quant_n_plus_v'::regclass);

-- ============================================================
-- 결합된 수량자 / 교대 테스트
-- ============================================================
CREATE TABLE rpr_glue (id INT, val INT);
INSERT INTO rpr_glue VALUES (1, 5), (2, 8), (3, 9), (4, -1), (5, 6), (6, -2);
-- 공백 없이 교대 연산자 '|'에 결합된 수량자.  렉서는 뒤따르는 '|'를 하나의 Op
-- 토큰으로 결합하며, 문법은 주변 시퀀스가 완성된 뒤 그것을 최하위 우선순위의
-- 교대로 다시 붙인다.

-- '|'에 결합된 연산자 문자 수량자 (*, +, ?, *?, +?, ??).
CREATE VIEW rpr_dp_op AS SELECT
    count(*) OVER w1 AS w1, count(*) OVER w2 AS w2, count(*) OVER w3 AS w3,
    count(*) OVER w4 AS w4, count(*) OVER w5 AS w5, count(*) OVER w6 AS w6
FROM rpr_glue
WINDOW w1 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*|B) DEFINE A AS val > 0, B AS val <= 0),
       w2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A+|B) DEFINE A AS val > 0, B AS val <= 0),
       w3 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A?|B) DEFINE A AS val > 0, B AS val <= 0),
       w4 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*?|B) DEFINE A AS val > 0, B AS val <= 0),
       w5 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A+?|B) DEFINE A AS val > 0, B AS val <= 0),
       w6 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A??|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT line FROM unnest(string_to_array(pg_get_viewdef('rpr_dp_op'), E'\n')) AS line WHERE line ~ 'PATTERN';
DROP VIEW rpr_dp_op;
-- 공백을 둔 참조 표기: 완전히 공백으로 분리된 정규 형태.  위의 결합된
-- rpr_dp_op w1/w4 와 동일한 디파스 결과가 결합형 = 공백형 = 혼합형의
-- 동등성을 완성한다.
CREATE VIEW rpr_dp_spc AS SELECT count(*) OVER w1 AS w1, count(*) OVER w2 AS w2
FROM rpr_glue
WINDOW w1 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A* | B) DEFINE A AS val > 0, B AS val <= 0),
       w2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*? | B) DEFINE A AS val > 0, B AS val <= 0);
SELECT line FROM unnest(string_to_array(pg_get_viewdef('rpr_dp_spc'), E'\n')) AS line WHERE line ~ 'PATTERN';
DROP VIEW rpr_dp_spc;
-- '|'에 결합된 범위 수량자: 비소극적 {n}| (} + 문자 '|')와 소극적 {n}?|
-- (} + Op "?|").
CREATE VIEW rpr_dp_rng AS SELECT
    count(*) OVER w1 AS w1, count(*) OVER w2 AS w2, count(*) OVER w3 AS w3, count(*) OVER w4 AS w4,
    count(*) OVER w5 AS w5, count(*) OVER w6 AS w6, count(*) OVER w7 AS w7, count(*) OVER w8 AS w8
FROM rpr_glue
WINDOW w1 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2}|B) DEFINE A AS val > 0, B AS val <= 0),
       w2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2,}|B) DEFINE A AS val > 0, B AS val <= 0),
       w3 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{,3}|B) DEFINE A AS val > 0, B AS val <= 0),
       w4 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2,3}|B) DEFINE A AS val > 0, B AS val <= 0),
       w5 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2}?|B) DEFINE A AS val > 0, B AS val <= 0),
       w6 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2,}?|B) DEFINE A AS val > 0, B AS val <= 0),
       w7 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{,3}?|B) DEFINE A AS val > 0, B AS val <= 0),
       w8 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2,3}?|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT line FROM unnest(string_to_array(pg_get_viewdef('rpr_dp_rng'), E'\n')) AS line WHERE line ~ 'PATTERN';
DROP VIEW rpr_dp_rng;
-- 혼합된 공백: 수량자 안에 공백이 있어도 '|'는 여전히 결합된다.  "A* ?|B" =
-- '*' + Op"?|" = 소극적 "A*?"에 교대가 붙은 것.
CREATE VIEW rpr_dp_mix AS SELECT count(*) OVER w1 AS w1, count(*) OVER w2 AS w2, count(*) OVER w3 AS w3
FROM rpr_glue
WINDOW w1 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A* ?|B) DEFINE A AS val > 0, B AS val <= 0),
       w2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A+ ?|B) DEFINE A AS val > 0, B AS val <= 0),
       w3 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A? ?|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT line FROM unnest(string_to_array(pg_get_viewdef('rpr_dp_mix'), E'\n')) AS line WHERE line ~ 'PATTERN';
DROP VIEW rpr_dp_mix;
-- 구조: 우선순위 (|가 가장 낮으므로 그 오른쪽 피연산자는 뒤따르는 시퀀스
-- 전체다), 연쇄, 연결, 그리고 그룹화.
CREATE VIEW rpr_dp_struct AS SELECT
    count(*) OVER w1 AS w1, count(*) OVER w2 AS w2, count(*) OVER w3 AS w3,
    count(*) OVER w4 AS w4, count(*) OVER w5 AS w5, count(*) OVER w6 AS w6
FROM rpr_glue
WINDOW w1 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*|B C) DEFINE A AS val > 0, B AS val <= 0, C AS val < 100),
       w2 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*|B*|C) DEFINE A AS val > 0, B AS val <= 0, C AS val < 100),
       w3 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A B*|C D) DEFINE A AS val > 0, B AS val <= 0, C AS val < 100, D AS val > 5),
       w4 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A*|B)) DEFINE A AS val > 0, B AS val <= 0),
       w5 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*|(B|C)) DEFINE A AS val > 0, B AS val <= 0, C AS val < 100),
       w6 AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A*|B)+) DEFINE A AS val > 0, B AS val <= 0);
SELECT line FROM unnest(string_to_array(pg_get_viewdef('rpr_dp_struct'), E'\n')) AS line WHERE line ~ 'PATTERN';
DROP VIEW rpr_dp_struct;
-- 실행 의미론 (디파스로는 소극적 최단 매치를 드러낼 수 없다).  rpr_glue 행들
-- -- A는 1-3 행과 5 행, B는 4 행과 6 행 -- 은 '|B' 대안이 언제 도달 가능한지를
-- 보여준다.  "*"에서는 첫 분기가 항상 성공하므로 B는 결코 작동하지 않는다:
-- 탐욕적 형태는 전체 구간에 매치하고 소극적 형태는 빈 매치가 되며, B 행에서도
-- 빈 매치가 여전히 B를 이긴다.  "+"에서는 첫 분기가 B 행에서 실패하므로
-- 그곳에서는 B 대안이 작동한다; A 행에서는 탐욕적 형태가 구간에 매치하고
-- 소극적 형태는 한 행에 매치한다.
SELECT id, val,
       count(*) OVER gs AS gstar, count(*) OVER rs AS rstar,
       count(*) OVER gp AS gplus, count(*) OVER rp AS rplus
FROM rpr_glue
WINDOW gs AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*|B) DEFINE A AS val > 0, B AS val <= 0),
       rs AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*?|B) DEFINE A AS val > 0, B AS val <= 0),
       gp AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A+|B) DEFINE A AS val > 0, B AS val <= 0),
       rp AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A+?|B) DEFINE A AS val > 0, B AS val <= 0);
-- 계속 거부되어야 하는 패턴들.  "&"는 유효하지 않은 연산자다; 한쪽이 빈
-- '|'(앞, 뒤, 중복, 또는 그룹 안에 홀로)는 피연산자가 없다; "||"와 "*||"는
-- 중복된 파이프다; "A* *|B"/"A* *?|B"/"A{2}*?|B"는 중복된 수량자다.
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A&B) DEFINE A AS val > 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*|) DEFINE A AS val > 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*| |B) DEFINE A AS val > 0, B AS val <= 0);
-- 매달린 연산자는 그것이 붙어 있는 요소의 탓으로 돌려지며, 첫 번째 요소의
-- 탓이 아니다
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A B*|) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*||B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A||B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*|B|) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (|A) DEFINE A AS val > 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A*|)) DEFINE A AS val > 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A* *|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A* *?|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A? *?|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2}*?|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A{2} *?|B) DEFINE A AS val > 0, B AS val <= 0);
-- 중복된 연산자 문자 수량자는 하나의 Op 토큰으로 렉싱되며, '|'에
-- 결합되든("**|", "*+|", "???|") 단독으로 쓰이든("**") 지원되지 않는다.
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A**|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A*+|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A???|B) DEFINE A AS val > 0, B AS val <= 0);
SELECT count(*) OVER w FROM rpr_glue WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN (A**B) DEFINE A AS val > 0);
DROP TABLE rpr_glue;

-- ============================================================
-- 오류 사례 테스트
-- ============================================================

DROP TABLE IF EXISTS rpr_err;
CREATE TABLE rpr_err (id INT, val INT);
INSERT INTO rpr_err VALUES (1, 10), (2, 20);

-- 잘못된 수량자 구문
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+!)
    DEFINE A AS val > 0
);

-- 아래 쿼리들은 어느 것도 받아들여져서는 안 된다
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A+ !) DEFINE A AS TRUE);
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A+ ?+) DEFINE A AS TRUE);
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A* ?+) DEFINE A AS TRUE);
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A? ??) DEFINE A AS TRUE);
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A {1,2}??) DEFINE A AS TRUE);

-- 아래 4 개의 범위 수량자 쿼리는 어느 것도 받아들여져서는 안 된다
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A{2} !) DEFINE A AS TRUE);
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A{2,} !) DEFINE A AS TRUE);
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A{,3} !) DEFINE A AS TRUE);
SELECT FROM rpr_err WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A{2,3} !) DEFINE A AS TRUE);

-- 짝이 맞지 않는 괄호
SET client_min_messages = NOTICE;
DO $$
BEGIN
    EXECUTE 'SELECT COUNT(*) OVER w FROM rpr_err WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING PATTERN ((A B) DEFINE A AS val > 0, B AS val > 10)';
    RAISE NOTICE 'Unmatched parentheses: UNEXPECTED SUCCESS';
EXCEPTION
    WHEN syntax_error THEN
        RAISE NOTICE 'Unmatched parentheses: EXPECTED ERROR - %', SQLERRM;
    WHEN OTHERS THEN
        RAISE NOTICE 'Unmatched parentheses: UNEXPECTED ERROR - %', SQLERRM;
END $$;
SET client_min_messages = WARNING;

-- ERROR: 빈 DEFINE은 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE
);

-- ERROR: 빈 PATTERN은 허용되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ()
    DEFINE A AS val > 0
);

-- ERROR: PATTERN 없는 DEFINE (PATTERN과 DEFINE은 함께 써야 한다)
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    DEFINE A AS val > 0
);

-- 한정된 열 참조 (지원되지 않음)

-- 패턴 변수 한정 이름: 지원되지 않음
-- (ISO/IEC 19075-5 6.15 / 4.16 에서는 유효하지만 아직 구현되지 않음)
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS A.val > 0
);

-- PATTERN에만 있는 변수의 한정 이름:
-- DEFINE 항목이 없어도 지원되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ B+)
    DEFINE A AS B.val > 0
);

-- 한정자로 쓰인, DEFINE에만 있는 변수
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0, B AS B.val > 0
);

-- FROM절 범위 변수 한정 이름: 허용되지 않는다
-- (ISO/IEC 19075-5 6.5 에 의해 금지됨)
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS rpr_err.val > 0
);

-- 알 수 없는 한정자 (패턴 변수도 범위 변수도 아님): 다른 한정된 이름과
-- 마찬가지로 거부되며, 없는 FROM절 항목으로 보고되지는 않는다.  하나를
-- 추가해도 위의 범위 변수 오류로 이어질 뿐이기 때문이다
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS nosuch.val > 0
);

-- 3 부분 이름은 첫 부분이 패턴 변수를 표기하더라도 스키마 한정으로 취급되며,
-- 다른 한정된 이름과 마찬가지로 거부된다
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (public+)
    DEFINE public AS public.rpr_err.val > 0
);

-- DEFINE 안의 한정자 없는 복합 필드 접근은 동작한다: 한정자가 없다는 것은
-- 패턴/범위 변수 내비게이션이 없다는 뜻이므로 사전 검사는 건너뛰고 일반적인
-- 풀이가 "(items).amount"를 현재 행에 대한 A_Indirection 노드로 처리한다.
CREATE TYPE rpr_item AS (name TEXT, amount INT);
CREATE TEMP TABLE rpr_composite (id int, items rpr_item);
INSERT INTO rpr_composite VALUES (1, ROW('a',5)), (2, ROW('b',15)), (3, ROW('c',25));
SELECT id, (items).amount, COUNT(*) OVER w AS cnt
FROM rpr_composite
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+)
    DEFINE A AS (items).amount > 10
);

-- 복합 타입 필드 선택 (한정된 형태): 인용되는 것은 ColumnRef 부분
-- ("A.items" 또는 "rpr_composite.items")이며, 뒤따르는 ".amount"는 주변의
-- A_Indirection 노드에 있고 사전 검사에는 보이지 않는다.
SELECT COUNT(*) OVER w
FROM rpr_composite
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS (A.items).amount > 10
);
SELECT COUNT(*) OVER w
FROM rpr_composite
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS (rpr_composite.items).amount > 10
);

-- 복합 열 뒤의 별표는 관계 뒤의 별표와는 다른 것이다: 그것은 어떤 관계도
-- 지칭하지 않으므로 행 생성자는 계속 그것을 펼치며 DEFINE 제약은
-- 적용되지 않는다.
SELECT COUNT(*) OVER w
FROM rpr_composite
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS ROW((items).*) IS NOT NULL
);

DROP TABLE rpr_composite;
DROP TYPE rpr_item;

-- 서브쿼리 Var를 거쳐 DEFINE에 도달하는 복합값은 풀업된 뒤에야 ROW(...) 모양을
-- 갖추며, ORDER BY 사본의 sortgroupref가 그것이 평탄화되는 것을 막는다.
-- make_window_input_target()이 그 분리로 남겨진 필드들을 추가한다.
CREATE TABLE rpr_ordrow (a int, b int);
INSERT INTO rpr_ordrow SELECT g, g % 4 FROM generate_series(1, 10) g;
SELECT count(*) OVER w AS c
FROM (SELECT ROW(a, b) AS x FROM rpr_ordrow) s
WINDOW w AS (ORDER BY x
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL PATTERN (P Q+) DEFINE P AS TRUE, Q AS x IS NOT NULL);
-- 대조군: ORDER BY가 없으면 x는 평범하게 평탄화되고 이것도 성공한다.
SELECT count(*) OVER w AS c
FROM (SELECT ROW(a, b) AS x FROM rpr_ordrow) s
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL PATTERN (P Q+) DEFINE P AS TRUE, Q AS x IS NOT NULL);
DROP TABLE rpr_ordrow;

-- 풀업된 복합 대상을 거친 같은 분리를, 평범한 서브쿼리로도 뷰로도 실행한다.
-- a가 같은 행은 같은 파티션을 공유하므로 q가 검사되고 DEFINE은 실제로
-- k를 읽는다.
CREATE TABLE rpr_partrow (a int, b int);
INSERT INTO rpr_partrow VALUES (1, 1), (1, 2), (1, 3), (2, 4);
SELECT count(*) OVER w
FROM (SELECT b, row(a, 1) AS k FROM rpr_partrow) s
WINDOW w AS (PARTITION BY k ORDER BY b
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  PATTERN (p q+) DEFINE q AS k IS NOT NULL);
CREATE TYPE rpr_partrow_t AS (x int, y int);
CREATE VIEW rpr_partrow_v AS SELECT b, row(a, 1)::rpr_partrow_t AS k FROM rpr_partrow;
SELECT count(*) OVER w FROM rpr_partrow_v
WINDOW w AS (PARTITION BY k ORDER BY b
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  PATTERN (p q+) DEFINE q AS k IS NOT NULL);
-- 대조군: PATTERN/DEFINE을 제외하면 같은 윈도우 절도 문제없이 실행된다.
SELECT count(*) OVER w
FROM (SELECT b, row(a, 1) AS k FROM rpr_partrow) s
WINDOW w AS (PARTITION BY k ORDER BY b
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING);
DROP VIEW rpr_partrow_v;
DROP TYPE rpr_partrow_t;
DROP TABLE rpr_partrow;

-- ERROR: DEFINE 안의 정의되지 않은 열
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS nonexistent_column > 0
);

-- ERROR: 타입 불일치
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 'string'
);

-- ERROR: DEFINE 안의 집계 함수는 지원되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS COUNT(*) > 0
);

-- ERROR: DEFINE 안의 그룹화 연산은 지원되지 않는다.  이는 위의 집계 사례와
-- EXPR_KIND_RPR_DEFINE 분기를 공유하지만, 그중 GroupingFunc 쪽을 탄다.
-- parseCheckAggregates()는 DEFINE을 finalize_grouping_exprs() 밖에 두기 위해
-- 이 거부에 의존한다.
SELECT COUNT(*) OVER w
FROM rpr_err
GROUP BY id
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS GROUPING(id) = 0
);

-- ERROR: DEFINE 안의 집합 반환 함수는 지원되지 않는다
SELECT FROM rpr_err
WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A+) DEFINE A AS 1 > generate_series(1 ,2));

-- ERROR: DEFINE 안의 윈도우 함수는 지원되지 않는다
SELECT FROM rpr_err
WINDOW w AS ( ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING PATTERN (A+) DEFINE A AS 1 > row_number() OVER ());

-- DEFINE 안의 서브쿼리는 지원되지 않는다
SELECT COUNT(*) OVER w
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > (SELECT max(val) FROM rpr_err)
);

-- PATTERN에 나타나지 않는 DEFINE 변수
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_err
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0, B AS val > 5, C AS val > 10
);

DROP TABLE rpr_err;

-- NULL 처리

CREATE TABLE rpr_null (id INT, val INT);
INSERT INTO rpr_null VALUES (1, 10), (2, NULL), (3, 30);

-- DEFINE 표현식 안의 NULL
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_null
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 15
);

-- DEFINE 안의 IS NULL
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_null
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (N+)
    DEFINE N AS val IS NULL
);

-- DEFINE 안의 IS NOT NULL
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_null
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (NN+)
    DEFINE NN AS val IS NOT NULL
);

DROP TABLE rpr_null;

-- 복합 내비게이션: 내부 내비게이션은 (표현식에 중첩되지 않은) 직접
-- 인자여야 한다
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(v + FIRST(v)) > 0
);

-- FIRST/LAST가 FIRST/LAST를 감싸는 경우: 금지됨
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS FIRST(FIRST(v)) > 0
);

-- 삼중 중첩: 금지됨 (3 단계 깊이의 내비게이션)
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(FIRST(PREV(v))) > 0
);

-- 형제 관계의 내비게이션: 금지되지만, 이는 더 깊은 중첩이 아니므로 내부
-- 내비게이션은 3 단계가 아니라 직접 인자가 아니라는 이유로 보고되어야 한다.
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(FIRST(v) + LAST(v)) > 0
);

-- 내비게이션 세 개지만, 내부 것은 이번에도 인자 전체가 아니므로 그것이
-- 보고되고 깊이까지는 도달하지 않는다
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(FIRST(PREV(v)) + 1) > 0
);

-- 내비게이션 오프셋은 실행 시점 상수여야 하며, 내비게이션 연산이면 안 된다
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(v, FIRST(1)) > 0);
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(v, FIRST(1) + 1) > 0);
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(v, NEXT(1, 0)) > 0);
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(FIRST(v), LAST(1)) > 0);
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(v, FIRST(v)) > 0);
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS NEXT(v, PREV(v, 1)) > 0);
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(FIRST(v, LAST(1)), 2) > 0);
SELECT count(*) OVER w
FROM generate_series(1,10) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(v, FIRST(1::bigint)) > 0);

-- 알 수 없는 타입의 리터럴 인자는 text로 풀린다; 그래도 여전히 열을
-- 참조해야 한다
SELECT count(*) OVER w
FROM generate_series(1,5) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV('foo') = 'bar');
SELECT count(*) OVER w
FROM generate_series(1,5) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV('foo'));
SELECT count(*) OVER w
FROM generate_series(1,5) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(NULL) IS NULL);
PREPARE rpr_navarg AS SELECT count(*) OVER w
FROM generate_series(1,5) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV($1) IS NULL);

-- int2 오프셋은 다른 암묵적 캐스트와 마찬가지로 int8 로 강제 변환된다
-- (평범한 0 과 동일)
SELECT count(*) OVER w
FROM generate_series(1,5) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(v, 0::smallint) = v);
SELECT count(*) OVER w
FROM generate_series(1,5) s(v)
WINDOW w AS (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+) DEFINE A AS PREV(v, 0) = v);

-- ============================================================
-- 패턴 최적화 테스트
-- ============================================================
-- 패턴 최적화를 위한 테스트
-- 최적화된 패턴을 확인하려면 EXPLAIN을 쓴다 ("Pattern: ..."로 표시됨)

CREATE TABLE rpr_plan (id INT, val INT);
INSERT INTO rpr_plan VALUES
    (1, 10), (2, 20), (3, 30), (4, 40), (5, 50),
    (6, 60), (7, 70), (8, 80), (9, 90), (10, 100);

-- 연속된 VAR 병합: A A A -> a{3}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A A A) DEFINE A AS val > 0);

-- 연속된 VAR 병합: A{2} A{3} -> a{5}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A{2} A{3}) DEFINE A AS val > 0);

-- 연속된 VAR 병합: A+ A* -> a+
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+ A*) DEFINE A AS val > 0);

-- 연속된 VAR 병합: A A+ -> a{2,}
-- 유한한 앞쪽 (A{1,1})이 무한한 자식(A+)을 만나는 경우다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A A+) DEFINE A AS val > 0);

-- 경계에서의 연속된 VAR 병합: A{1073741823,} A{1073741823,} -> a{2147483646,}.
-- 최솟값 합 2147483646 = INT32_MAX - 1 이 여전히 유한한 한계 중 가장 큰
-- 값이므로 병합이 진행된다; 합이 정확히 INF가 되면 대신 폴백한다
-- (최적화 폴백 테스트 참고).
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A{1073741823,} A{1073741823,}) DEFINE A AS val > 0);

-- 유한한 수량자를 가진 연속 GROUP 병합:
-- ((A B){5}) ((A B){10}) -> 병합됨
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (((A B){5}) ((A B){10})) DEFINE A AS val <= 50, B AS val > 50);

-- 무한 수량자를 가진 연속 GROUP 병합: (A B)+ (A B)+ -> (a b){2,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B)+ (A B)+) DEFINE A AS val <= 50, B AS val > 50);

-- 연속 GROUP 병합: (A B){2} (A B)+ -> (a b){3,} 유한한 앞쪽 ((A B){2,2})이
-- 무한한 자식((A B)+)을 만나는 경우다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B){2} (A B)+) DEFINE A AS val <= 50, B AS val > 50);

-- 경계에서의 연속 GROUP 병합:
-- (A B){1073741823,} (A B){1073741823,}
-- -> (a b){2147483646,}.  최솟값 합 INT32_MAX - 1 은 여전히 유한하므로 병합이
-- 진행된다; 합이 정확히 INF가 되면 대신 폴백한다 (최적화 폴백 테스트 참고).
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B){1073741823,} (A B){1073741823,}) DEFINE A AS val <= 50, B AS val > 50);

-- PREFIX 병합: A B (A B)+ -> (a b){2,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B (A B)+) DEFINE A AS val <= 50, B AS val > 50);

-- PREFIX와 SUFFIX 병합: A B (A B)+ A B -> (a b){3,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B (A B)+ A B) DEFINE A AS val <= 40, B AS val > 40);

-- 중첩된 것을 평탄화: A ((B) (C)) -> a b c
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A ((B) (C))) DEFINE A AS val <= 30, B AS val <= 60, C AS val > 60);

-- 데이터 실행: SEQ 평탄화가 올바른 결과를 낸다
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP TO NEXT ROW
             PATTERN (A ((B) (C))) DEFINE A AS val <= 30, B AS val <= 60, C AS val > 60);

-- ALT 평탄화: (A | (B | C))+ -> (a | b | c)+
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A | (B | C))+) DEFINE A AS val <= 30, B AS val <= 60, C AS val > 60);

-- ALT 중복 제거: (A | B | A) -> (a | b)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A | B | A)+) DEFINE A AS val <= 50, B AS val > 50);

-- 데이터 실행: ALT 중복 제거가 올바른 결과를 낸다
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW
             PATTERN ((A | B | A)+) DEFINE A AS val <= 50, B AS val > 50);

-- 수량자 곱셈: (A{2}){3} -> a{6}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2}){3}) DEFINE A AS val > 0);

-- 수량자 곱셈: (((A B){2}?){3}) -> (a b){6}
-- {2}?는 고정된 개수를 가지므로 소극성이 정규화되어 없어지고,
-- (((A B){2}){3})에 적용되는 곱셈이 여기에도 적용된다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (((A B){2}?){3}) DEFINE A AS val > 0, B AS val > 0);

-- 수량자 곱셈 대조군: 탐욕적 GROUP (((A B){2}){3}) -> (a b){6}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (((A B){2}){3}) DEFINE A AS val > 0, B AS val > 0);

-- 자식이 범위인 수량자 곱셈: (A{2,3}){3} -> a{6,9} 바깥은 정확한 값, 자식은
-- 범위 - 최적화가 적용된다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2,3}){3}) DEFINE A AS val > 0);

-- 수량자 곱셈 없음: (A{2}){2,3}은 (a{2}){2,3}로 남는다
-- 바깥이 범위 - 간격이 생긴다 (4,6 이지 4,5,6 이 아님), 최적화 없음
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2}){2,3}) DEFINE A AS val > 0);

-- 수량자 곱셈 없음: (A{2}){2,}는 (a{2}){2,}로 남는다 바깥이 무한 - 간격이
-- 생긴다 (4,6,8,...이지 4,5,6,...이 아님), 최적화 없음
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2}){2,}) DEFINE A AS val > 0);

-- 수량자 곱셈: (A){2,} -> a{2,}
-- 자식이 정확히 1 - 간격 없음, 최적화가 적용된다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A){2,}) DEFINE A AS val > 0);

-- 수량자 곱셈: (A)+ -> a+
-- 자식이 정확히 1 - 간격 없음, 최적화가 적용된다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A)+) DEFINE A AS val > 0);

-- 수량자 곱셈 없음: (A{2}){3,5}는 (a{2}){3,5}로 남는다
-- 바깥이 범위, 자식이 1 보다 큰 정확한 값 - 간격이 생긴다
-- (6,8,10 이지 6,7,8,9,10 이 아님)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2}){3,5}) DEFINE A AS val > 0);

-- 수량자 곱셈 거부: (A{2,3}){2,3}은 중첩된 채로 남는다.
-- 개수 [4,6] U [6,9] = [4,9]는 이어지지만, 미달할 하한을 가진 유한한 자식
-- 때문에 중첩된 형태가 a{4,9}보다 더 짧은 매치를 선호하게 된다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2,3}){2,3}) DEFINE A AS val > 0);

-- 수량자 곱셈 없음: (A{4,5}){2,3}는 (a{4,5}){2,3}로 남는다
-- 바깥이 범위, 자식이 간격을 가진 범위: [8,10] U [12,15]는 11 을 놓친다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{4,5}){2,3}) DEFINE A AS val > 0);

-- 중첩된 무한: (A*)* -> a*
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A*)*) DEFINE A AS val > 0);

-- 중첩된 무한: (A+)* -> a*
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A+)*) DEFINE A AS val > 0);

-- 중첩된 무한: (A+)+ -> a+
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A+)+) DEFINE A AS val > 0);

-- 무한한 자식을 가진 수량자 곱셈: 바깥의 정확한 개수(m == n)는 자식의 최댓값과
-- 무관하게 항상 접힌다 - (A+){3} -> a{3,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A+){3}) DEFINE A AS val > 0);

-- (A{2,}){3} -> a{6,}  (m == n, 최솟값이 2 인 무한 자식)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2,}){3}) DEFINE A AS val > 0);

-- (A+){2,4} -> a{2,}  (바깥이 범위, 자식이 무한: 모든 구간이
-- INF에 도달하므로 항상 맞닿는다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A+){2,4}) DEFINE A AS val > 0);

-- (A{2,3}){2,4}는 위의 (A{2,3}){2,3}처럼 중첩된 채로 남는다.  비록 개수 [4,6]
-- U [6,9] U [8,12] = [4,12]가 이어지더라도 그렇다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2,3}){2,4}) DEFINE A AS val > 0);

-- 건너뛸 수 있는 바깥(최솟값 0)은 0 인 경우가 자식의 범위와 이어질 때만
-- 접힌다: (A{1,3})?  -> a{0,3}
-- (자식의 최솟값 <= 1 이므로 {0} U [1,3] = [0,3]이 이어진다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{1,3})?) DEFINE A AS val > 0);

-- 수량자 곱셈 없음: (A{2,3})?는 (a{2,3})?로 남는다
-- 최솟값 0 에 자식의 최솟값이 2 이상: {0} U [2,3]은 1 에 도달할 수 없게 남긴다
-- (구간은 맞닿지만 0 인 경우는 이어지지 않는다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2,3})?) DEFINE A AS val > 0);

-- 수량자 곱셈 없음: (A{3,4})?는 (a{3,4})?로 남는다
-- 최솟값 0 에 자식의 최솟값이 2 이상: {0} U [3,4]는 1,2 에 도달할 수
-- 없게 남긴다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{3,4})?) DEFINE A AS val > 0);

-- GROUP{1,1} 풀기: (A) -> a
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A)) DEFINE A AS val > 0);

-- GROUP{1,1} 풀기: (A B) -> a b
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B)) DEFINE A AS val <= 50, B AS val > 50);

-- 조합된 최적화: A A (B B)+ B B C C C -> a{2} (b{2}){2,} c{3}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A A (B B)+ B B C C C)
             DEFINE A AS val <= 20, B AS val > 20 AND val <= 70, C AS val > 70);

-- GROUP을 푼 뒤 VAR 병합: (A+) (A+) -> a{2,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A+) (A+)) DEFINE A AS val > 0);

-- 유한한 수량자 곱셈: (A{10}){20} -> a{200}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{10}){20}) DEFINE A AS val > 0);

-- 서로 다른 GROUP은 병합을 막는다: (A B){2} (C D){3}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B){2} (C D){3})
             DEFINE A AS val <= 25, B AS val > 25 AND val <= 50,
                    C AS val > 50 AND val <= 75, D AS val > 75);

-- 자식 개수가 다르면 병합을 막는다: (A B)+ (A B C)+
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B)+ (A B C)+)
             DEFINE A AS val <= 33, B AS val > 33 AND val <= 66, C AS val > 66);

-- PREFIX만 병합: A B (A B)+ -> (a b){2,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B (A B)+) DEFINE A AS val <= 50, B AS val > 50);

-- SUFFIX만 병합: (A B)+ A B -> (a b){2,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B)+ A B) DEFINE A AS val <= 50, B AS val > 50);

-- 여러 개의 SUFFIX 흡수: (A B)+ A B A B C
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B)+ A B A B C)
             DEFINE A AS val <= 50, B AS val > 50 AND val <= 75, C AS val > 75);

-- 남은 PREFIX가 있는 PREFIX 병합: A B C D (C D)+  -> A B (C D) {2,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B C D (C D)+)
             DEFINE A AS val <= 25, B AS val > 25 AND val <= 50,
                    C AS val > 50 AND val <= 75, D AS val > 75);

-- 병합할 수 없음, prefix가 다르다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w
FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
PATTERN (A B C D C (C D) +)
DEFINE A AS val <= 25, B AS val > 25,
       C AS val > 50, D AS val > 75);

-- 수량자를 가진 PREFIX 병합: A B* (A B*)+ -> (a b*){2,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B* (A B*)+)
             DEFINE A AS val <= 50, B AS val > 50);

-- 여러 수량자를 가진 PREFIX 병합:
-- A+ B* C? (A+ B* C?)+ -> (a+ b* c?){2,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+ B* C? (A+ B* C?)+)
             DEFINE A AS val <= 30, B AS val > 30 AND val <= 60, C AS val > 60);

-- SUFFIX 병합 거부: (A B*)+ A B*는 그대로 남는다.  본문 A B*는 고정된 행 수를
-- 갖지 않으므로, 끝의 사본을 그룹 안으로 접어 넣으면 그룹의 정지 판단이 그
-- 사본 자신의 선택보다 앞서게 된다.  바로 위의 PREFIX 병합은 같은 종류의
-- 본문에 대해서도 계속 동작한다 -- 앞선 사본은 필수이므로 아무것도 순서를
-- 바꾸지 않고 병합된다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B*)+ A B*)
             DEFINE A AS val <= 50, B AS val > 50);

-- GROUP{1,1} 풀기: ((A | B | C)) -> (a | b | c)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A | B | C)) DEFINE A AS val <= 30, B AS val <= 60, C AS val > 60);

-- 데이터 실행: GROUP 풀기가 올바른 결과를 낸다
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP TO NEXT ROW
             PATTERN ((A | B | C)) DEFINE A AS val <= 30, B AS val <= 60, C AS val > 60);

-- 소극적 최적화 우회: VAR 병합
-- A+? A는 a+? a로 남는다 (탐욕적 A+ A는 a{2,}로 병합된다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A+? A) DEFINE A AS val > 0);

-- 소극적 최적화 우회: GROUP{1,1} 풀기 이후의 SUFFIX 병합 (A B)+?  (A B)는
-- (a b)+?  a b로 남는다 (탐욕적이면 (a b){2,}로 병합된다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B)+? (A B)) DEFINE A AS val <= 50, B AS val > 50);

-- 소극적 최적화 우회: 수량자 곱셈 (바깥이 소극적) (A+){2,4}?는 중첩된 채로
-- 남지만, 탐욕적인 (A+){2,4}는 a{2,}로 곱해진다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A+){2,4}?) DEFINE A AS val > 0);

-- 소극적 최적화 우회: 수량자 곱셈 (안쪽이 소극적) (A{2,3}?){3}는
-- (a{2,3}?){3}로 남는다 (탐욕적인 (A{2,3}){3}는 a{6,9}로 병합된다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2,3}?){3}) DEFINE A AS val > 0);

-- 고정 개수는 정규화되어 없어진다: (A{2}?){3} -> a{6}, (A{2}){3}과 같다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A{2}?){3}) DEFINE A AS val > 0);

-- {0,}은 무한한 최솟값 0 에 도달하는 유일한 중괄호 표기다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A{0,}) DEFINE A AS val > 0);

-- 맨 {1}과 {1,1}은 VAR에도 GROUP에도 수량자를 남기지 않는다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A{1} B{1,1} (C){1})
             DEFINE A AS val <= 30, B AS val <= 60, C AS val > 60);

-- 소극적 {1,1}은 맨 변수로 정규화된다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A{1,1}? (B C){1})
             DEFINE A AS val <= 30, B AS val <= 60, C AS val > 60);

-- 소극적 최적화 우회: PREFIX 병합
-- A B (A B)+?는 분리된 채로 남는다 (탐욕적이면 (a b){2,}로 병합된다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B (A B)+?) DEFINE A AS val <= 50, B AS val > 50);

-- 소극적 최적화 우회: SUFFIX 병합
-- (A B)+? A B는 분리된 채로 남는다 (탐욕적이면 (a b){2,}로 병합된다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A B)+? A B) DEFINE A AS val <= 50, B AS val > 50);

-- 수량자 전파를 동반한 GROUP 풀기: (A)?? B -> a?? b
-- 단일 VAR 자식 {1,1}은 GROUP의 수량자와 소극성을 물려받는다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A)?? B) DEFINE A AS val <= 50, B AS val > 50);

-- ALT 평탄화를 거쳐서도 유지되는 소극성
-- (A | (B | C))+?는 (a | b | c)+?로 평탄화된다 - 내부 ALT는 평탄화되었지만
-- 소극성은 유지된다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A | (B | C))+?) DEFINE A AS val <= 30, B AS val <= 60, C AS val > 60);

-- 소극적 최적화 우회: 흡수 플래그
-- SKIP PAST LAST ROW를 쓴 A+? - 흡수 마커 없음 (탐욕적 A+는 a+#가 된다)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (A+?) DEFINE A AS val > 0);

-- 중복 GROUP 제거: ((A | B)+ | (A | B)+) -> (a | b)+
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A | B)+ | (A | B)+) DEFINE A AS val <= 50, B AS val > 50);

-- 최솟값 0 을 가진 연속 VAR 병합: A* A+ -> a+
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A* A+) DEFINE A AS val > 0);

-- 연속 VAR 병합 (요소 4 개): A A{2} A+ A{3} -> a{7,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A A{2} A+ A{3}) DEFINE A AS val > 0);

-- PREFIX+SUFFIX 병합 (5 개 짜리): A B A B (A B)+ A B A B -> (a b){5,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B A B (A B)+ A B A B)
             DEFINE A AS val <= 50, B AS val > 50);

-- PREFIX+SUFFIX 병합 (5 개 짜리): B A B (A B)+ A B A B -> b (a b){4,}
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (B A B (A B)+ A B A B)
             DEFINE A AS val <= 50, B AS val > 50);

-- 중복 제거 후 단일 항목 ALT 풀기: (A | A)+ -> a+ ALT 중복 제거가 단일
-- 항목으로 줄인 뒤, 수량자 곱셈이 GROUP을 접는다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN ((A | A)+) DEFINE A AS val > 0);

-- 평탄화를 동반한 GROUP{1,1}을 SEQ로: ((A B)(C D)) -> a b c d
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (((A B)(C D)))
             DEFINE A AS val <= 25, B AS val > 25 AND val <= 50,
                    C AS val > 50 AND val <= 75, D AS val > 75);

-- 중첩된 ALT 패턴: ((A B) | C) D | A B C
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (((A B) | C) D | A B C)
             DEFINE A AS val <= 25, B AS val > 25 AND val <= 50,
                    C AS val > 50 AND val <= 75, D AS val > 75);

-- 무한을 포함한 중첩 ALT: ((A+ B) | C) D | A B C
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (((A+ B) | C) D | A B C)
             DEFINE A AS val <= 25, B AS val > 25 AND val <= 50,
                    C AS val > 50 AND val <= 75, D AS val > 75);

-- ============================================================
-- 흡수 플래그 표시 테스트
-- ============================================================
-- EXPLAIN 출력에서의 흡수 마커 표시를 테스트한다 마커: ~ = 분기 요소, # =
-- 비교 지점

-- 단순 VAR: A+ -> a+# (비교 지점)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (A+) DEFINE A AS val > 0);

-- 무한 GROUP: (A B)+ -> (a~ b~)+# (분기 + 비교)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ((A B)+) DEFINE A AS val <= 50, B AS val > 50);

-- 둘 다 흡수 가능한 ALT: A+ | B+ -> (a+# | b+#)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (A+ | B+) DEFINE A AS val <= 50, B AS val > 50);

-- 하나만 흡수 가능한 ALT: A+ | B -> (a+# | b)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (A+ | B) DEFINE A AS val <= 50, B AS val > 50);

-- 흡수 가능하게 시작하는 시퀀스: A+ B -> a+# b
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (A+ B) DEFINE A AS val <= 50, B AS val > 50);

-- 복합 중첩: ((A+ B) | C) D | A B C - 깊이 중첩된 ALT
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (((A+ B) | C) D | A B C)
             DEFINE A AS val <= 30, B AS val <= 60, C AS val <= 80, D AS val > 80);

-- ALT 분기 꼬리는 과하게 표시되지 않음: A | (B C)+ (D E)+ ->
-- (a | (b~ c~)+# (d e)+)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (A | (B C)+ (D E)+)
             DEFINE A AS val <= 20, B AS val <= 40, C AS val <= 60, D AS val <= 80, E AS val > 80);

-- 중첩된 무한: (A+ | B)+ -> (a+# | b)+ (첫 반복이 흡수 가능)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ((A+ | B)+)
             DEFINE A AS val <= 50, B AS val > 50);

-- 무한 GROUP 안의 ALT: (A+ B | A B)* -> (a+# b | a b)* (첫 반복이 흡수 가능)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ((A+ B | A B)*)
             DEFINE A AS val <= 50, B AS val > 50);

-- 흡수 가능한 고정 길이 그룹: (A{2} B{3})+ -> (a{2}~ b{3}~)+# 모든 자식이 min
-- == max를 가지며, {1,1}로 풀어 쓴 것과 동등하다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ((A{2} B{3})+)
             DEFINE A AS val <= 50, B AS val > 50);

-- 중첩된 고정 길이 그룹: (A (B C){2} D)+ -> 흡수 가능
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ((A (B C){2} D)+)
             DEFINE A AS val <= 20, B AS val <= 40, C AS val <= 60, D AS val > 60);

-- 안쪽에 수량자를 가진 중첩 고정 길이: ((A{2} B{3}){2})+ -> 흡수 가능
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (((A{2} B{3}){2})+)
             DEFINE A AS val <= 50, B AS val > 50);

-- 흡수 불가능한 고정 길이: (A B{2,5})+ -> 마커 없음 (min != max)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ((A B{2,5})+)
             DEFINE A AS val <= 50, B AS val > 50);

-- 흡수 불가능한 고정 길이: (A B?)+ -> 마커 없음 (min != max)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ((A B?)+)
             DEFINE A AS val <= 50, B AS val > 50);

-- 흡수 불가능 (무한이 시작이 아님): A B+ -> a b+ (마커 없음)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (A B+) DEFINE A AS val <= 50, B AS val > 50);

-- 흡수 불가능 (무한 분기 없음):
-- (A | B){2,} -> (a | b){2,} (마커 없음)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ((A | B){2,}) DEFINE A AS val <= 50, B AS val > 50);

-- 흡수 불가능 (SKIP TO NEXT ROW): A+ -> a+ (마커 없음)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP TO NEXT ROW PATTERN (A+) DEFINE A AS val > 0);

-- 흡수 불가능 (제한된 프레임): A+ -> a+ (마커 없음)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND 10 FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (A+) DEFINE A AS val > 0);

-- 인용된 변수 이름에서 마커는 닫는 따옴표 바깥에 붙는다: 키워드 이름도 비교
-- 지점을 갖는다, "select"+ -> "select"+#
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN ("select"+ B)
             DEFINE "select" AS val <= 50, B AS val > 50);

-- 공백 때문에 인용된 이름에서도 분기 마커는 마찬가지다:
-- ("My Var" A)+ -> ("My Var"~ a~)+#
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_plan
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             AFTER MATCH SKIP PAST LAST ROW PATTERN (("My Var" A)+ B)
             DEFINE "My Var" AS val <= 25, A AS val <= 50, B AS val > 50);

-- 소극적 {1}? 수량자: min == max이므로 계획이 그것을 정규화해 없앤다
EXPLAIN (COSTS OFF) SELECT count(*) OVER w
FROM rpr_plan
WINDOW w AS (
    ORDER BY val
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1}? B)
    DEFINE A AS val > 0, B AS val > 0
);

-- ============================================================
-- 흡수 분석 테스트
-- ============================================================
-- 컨텍스트 흡수 최적화를 테스트한다 (O(n^2) -> O(n))

-- 단순 흡수 가능 패턴: A+ B
-- 무한 VAR로 시작하는 패턴

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B)
    DEFINE A AS val <= 50, B AS val > 50
);

-- 흡수 가능한 GROUP 패턴: (A B)+ C
-- 무한 GROUP으로 시작하는 패턴

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B)+ C)
    DEFINE A AS val <= 30, B AS val > 30 AND val <= 60, C AS val > 60
);

-- 흡수 불가능: 무한이 시작이 아님
-- 패턴: A B+ (무한이 시작이 아님)

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS val <= 50, B AS val > 50
);

-- 흡수 가능한 분기를 가진 ALT
-- 패턴: (A+ | B+) C - 두 분기 모두 흡수 가능

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+ | B+) C)
    DEFINE A AS val <= 30, B AS val > 30 AND val <= 60, C AS val > 60
);

-- 분기가 섞인 ALT
-- 패턴: (A+ | B C)+ - 첫 분기만 흡수 가능

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+ | B C)+)
    DEFINE A AS val <= 30, B AS val > 30 AND val <= 60, C AS val > 60
);

-- 흡수 불가능: GROUP 안의 ALT
-- 패턴: (A | B){2,} - 무한 GROUP 안의 ALT

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B){2,})
    DEFINE A AS val <= 50, B AS val > 50
);

-- 중첩된 무한: 안쪽 GROUP만 흡수 가능
-- 패턴: ((A B)+ C)+ - 첫 반복에서 안쪽 (A B)+가 흡수 가능

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A B)+ C)+)
    DEFINE A AS val <= 30, B AS val > 30 AND val <= 60, C AS val > 60
);

-- 흡수 불가능: GROUP 안의 무한 요소
-- 패턴: (A B+){2,} - GROUP 안의 무한

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B+){2,})
    DEFINE A AS val <= 50, B AS val > 50
);

-- 실행 시점 조건: SKIP TO NEXT ROW
-- SKIP TO NEXT ROW에서는 흡수가 비활성화된다

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+ B)
    DEFINE A AS val <= 50, B AS val > 50
);

-- 실행 시점 조건: 제한된 프레임
-- 프레임 끝이 제한되면 흡수가 비활성화된다

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND 5 FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B)
    DEFINE A AS val <= 50, B AS val > 50
);

-- ALT의 흡수 불가능한 분기 매치: A+ B | C
-- 흡수 불가능한 분기의 C 매치(id=2, id=5)는 지배적인 A+ 실행의 흡수에서
-- 살아남아야 한다.  그 A+는 (B가 나타나지 않으므로) 결코 매치를
-- 완료하지 않는다

WITH test_nonabsorbable_branch AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A']),
        (2, ARRAY['A', 'C']),
        (3, ARRAY['A']),
        (4, ARRAY['A']),
        (5, ARRAY['A', 'C']),
        (6, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_nonabsorbable_branch
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B | C)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- 고정된 행 수를 위해 그룹 본문을 측정하기.  SUFFIX 병합은 시퀀스의 나머지가
-- 뒤따르는 그룹의 본문을 측정하므로, 아래 각 패턴은 검사 대상 모양을 그런 그룹
-- 안에 넣는다.  각 측정은 "not a fixed length"를 보고해야 한다: 첫 번째는 반복
-- 횟수가 범위이기 때문이고, 나머지 둘은 오버플로하기 때문이다.  실제 행에
-- 매치할 수 있는 것은 첫 번째 패턴뿐이다.

-- 반복 횟수가 범위인 중첩 그룹은 고정 길이를 갖지 않는다
SELECT id, val, COUNT(*) OVER w AS cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A B){1,2} C)+ D)
    DEFINE A AS val <= 30, B AS val > 30, C AS val > 0, D AS val > 0
);

-- 본문 길이 곱하기 횟수가 상한에 도달하는 고정 반복
SELECT id, val, COUNT(*) OVER w AS cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (((A B C){1000000000})+ D)
    DEFINE A AS val <= 30, B AS val > 30, C AS val > 0, D AS val > 0
);

-- 구성원들의 합이 상한을 넘는 본문
SELECT id, val, COUNT(*) OVER w AS cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A{2000000000} B{2000000000})+ C)
    DEFINE A AS val <= 30, B AS val > 30, C AS val > 0
);

-- 두 분기 모두 흡수 가능한 ALT: A+ C | B+
-- A+ C는 (C가 없으므로) 결코 완료되지 않아 그 A+ 실행은 계속 확장되며
-- 지배적이다; 다른 분기의 확정된 B+ 매치
-- (id=1, id=6)는 흡수에서 살아남아야 한다

WITH test_absorbable_branches AS (
    SELECT * FROM (VALUES
        (1, ARRAY['A', 'B']),
        (2, ARRAY['A', 'B']),
        (3, ARRAY['A', 'B']),
        (4, ARRAY['A']),
        (5, ARRAY['A']),
        (6, ARRAY['A', 'B']),
        (7, ARRAY['A', 'B']),
        (8, ARRAY['A', 'B']),
        (9, ARRAY['A'])
    ) AS t(id, flags)
)
SELECT id, flags,
       first_value(id) OVER w AS match_start,
       last_value(id) OVER w AS match_end
FROM test_absorbable_branches
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ C | B+)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags),
        C AS 'C' = ANY(flags)
);

-- ============================================================
-- 에지 케이스 테스트
-- ============================================================
-- 경계 조건과 복합적인 시나리오를 테스트한다

-- 빈 매치 방지
-- 빈 매치가 가능할 수 있는 패턴: A*

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A*)
    DEFINE A AS val > 1000  -- 결코 매치되지 않음
);

-- 모든 행 매치
-- 모든 행이 매치되는 패턴

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val >= 0  -- 항상 참
);

-- 큰 수량자
-- 패턴: A{100} (큰 정확한 수량자)

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{100})
    DEFINE A AS val > 0
);

-- 패턴: A{10,20} (큰 범위 수량자)
SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{10,20})
    DEFINE A AS val > 0
);

-- 복합 다단계 중첩
-- 패턴: (((A B) | C)+ D)+

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((((A B) | C)+ D)+)
    DEFINE A AS val <= 20, B AS val > 20 AND val <= 40,
           C AS val > 40 AND val <= 60, D AS val > 60
);

-- 긴 교대 연쇄
-- 패턴: A | B | C | D | E (5 방향 ALT)

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A | B | C | D | E)
    DEFINE A AS val = 10, B AS val = 30, C AS val = 50,
           D AS val = 70, E AS val = 90
);

-- 긴 시퀀스
-- 패턴: A B C D E F G H (8 개 요소 SEQ)

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B C D E F G H)
    DEFINE A AS val >= 10, B AS val >= 20, C AS val >= 30,
           D AS val >= 40, E AS val >= 50, F AS val >= 60,
           G AS val >= 70, H AS val >= 80
);

-- 뒤섞인 수량자
-- 패턴: A{2} B+ C{3,5} D* E{1,}

SELECT id, val, COUNT(*) OVER w as cnt
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{2} B+ C{3,5} D* E{1,})
    DEFINE A AS val > 0, B AS val > 0, C AS val > 0,
           D AS val > 0, E AS val > 0
);

-- ============================================================
-- 최적화 폴백 테스트
-- ============================================================
-- 최적화의 경계 사례와 폴백 동작을 테스트한다

CREATE TABLE rpr_fallback (id INT, val INT);
INSERT INTO rpr_fallback VALUES (1, 10), (2, 20);

-- 최솟값 수량자 오버플로가 최적화 폴백을 일으킨다 (min == max인 경우)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A{2000000000}){2})
    DEFINE A AS val > 0
);

-- 최댓값만의 수량자 오버플로가 최적화 폴백을 일으킨다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A{1,2000000000}){2})
    DEFINE A AS val > 0
);

-- 최댓값 수량자가 유효 범위를 넘는다
-- (2147483647 = INT_MAX, 한계값은 2147483646)
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A{2000000000,2147483647}){2})
    DEFINE A AS val > 0
);

-- 큰 최솟값을 가진 중첩 무한이 오버플로 폴백을 일으킨다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A{2000000000,}){2000000000,})
    DEFINE A AS val > 0
);

-- prefix 불일치가 최적화 폴백을 일으킨다
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B (C D)+)
    DEFINE A AS val > 0, B AS val > 5, C AS val > 10, D AS val > 15
);

-- 최솟값 합이 정확히 INF가 되는 연속 VAR 병합은 폴백을 일으킨다.
-- 1073741824 + 1073741823 = 2147483647 = INT32_MAX = RPR_QUANTITY_INF.
-- 병합하면 min == INF인 VAR가 생길 것이므로, 병합은 폴백해야 하고 두 VAR는
-- 병합되지 않은 채로 남아야 한다 (곱셈 경로의 >= INF 가드를 반영한다).
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1073741824,} A{1073741823,})
    DEFINE A AS val > 0
);

-- 그 합보다 1 큰 값은 int32 에 들어가지 않는다.  폴백은 위 사례와 같아
-- 보이지만, 이번에는 >= INF 비교가 아니라 오버플로 검사에 걸린다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1073741825,} A{1073741823,})
    DEFINE A AS val > 0
);

-- 최댓값 합이 정확히 INF에 닿으면 VAR 병합은 폴백한다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1,1073741823} A{1,1073741824})
    DEFINE A AS val > 0
);
-- 그 합보다 1 작은 값이 병합이 유지할 수 있는 가장 큰 최댓값이다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1,1073741822} A{1,1073741824})
    DEFINE A AS val > 0
);
-- 그보다 1 큰 값은 int32 에 들어가지 않는다; 오버플로 검사가 거부한다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1,1073741824} A{1,1073741824})
    DEFINE A AS val > 0
);
-- 이미 무한인 피연산자는 그래도 병합된다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A{1,1073741823} A{1,})
    DEFINE A AS val > 0
);
-- 최솟값 합이 정확히 INF가 되는 연속 GROUP 병합은 폴백을 일으킨다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A B){1073741824,} (A B){1073741823,})
    DEFINE A AS val > 0, B AS val > 5
);

-- 최댓값 합이 정확히 INF가 되는 연속 GROUP 병합은 폴백을 일으키며, 이보다 하나
-- 적은 값은 병합된다.  가드가 없다면 병합된 최댓값은 INF와 같아져 유한했던
-- 패턴이 무한이 되어 버린다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A B){1,1073741823} (A B){1,1073741824})
    DEFINE A AS val > 0, B AS val > 5
);
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A B){1,1073741822} (A B){1,1073741824})
    DEFINE A AS val > 0, B AS val > 5
);

-- prefix 병합은 반복 1 회를 더하므로, 최솟값이 이미 INF - 1 이거나 최댓값이
-- 이미 INF - 1 이면 거부한다; 둘 중 하나보다 1 작으면 병합된다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B (A B){2147483646,})
    DEFINE A AS val > 0, B AS val > 5
);
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B (A B){2147483645,})
    DEFINE A AS val > 0, B AS val > 5
);
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B (A B){1,2147483646})
    DEFINE A AS val > 0, B AS val > 5
);
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B (A B){1,2147483645})
    DEFINE A AS val > 0, B AS val > 5
);

-- suffix 병합도 prefix 병합과 같은 경계를 갖는다.
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A B){2147483646,} A B)
    DEFINE A AS val > 0, B AS val > 5
);
EXPLAIN (COSTS OFF)
SELECT COUNT(*) OVER w FROM rpr_fallback
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN ((A B){2147483645,} A B)
    DEFINE A AS val > 0, B AS val > 5
);

DROP TABLE rpr_fallback;

-- ============================================================
-- 플래너 통합 테스트
-- ============================================================
-- 전체 계획 파이프라인과 WindowAgg 플랜 노드 생성을 테스트한다

CREATE TABLE rpr_planner (id INT, category VARCHAR(10), val INT);
INSERT INTO rpr_planner VALUES
    (1, 'A', 10), (2, 'A', 20), (3, 'A', 30),
    (4, 'B', 40), (5, 'B', 50), (6, 'B', 60),
    (7, 'C', 70), (8, 'C', 80), (9, 'C', 90);

-- 같은 쿼리 안의 여러 윈도우 함수
SELECT id, category, val,
       COUNT(*) OVER w1 as cnt1,
       COUNT(*) OVER w2 as cnt2
FROM rpr_planner
WINDOW w1 AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
),
w2 AS (
    PARTITION BY category
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (B+)
    DEFINE B AS val >= 40
);

-- PARTITION BY를 가진 윈도우 함수

SELECT id, category, val,
       COUNT(*) OVER w as cnt
FROM rpr_planner
WINDOW w AS (
    PARTITION BY category
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 복합 ORDER BY를 가진 윈도우 함수

SELECT id, category, val,
       COUNT(*) OVER w as cnt
FROM rpr_planner
WINDOW w AS (
    ORDER BY category DESC, val ASC
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 이름 붙은 윈도우 참조

SELECT id, category, val,
       COUNT(*) OVER w as cnt
FROM rpr_planner
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 인라인 윈도우 정의

SELECT id, category, val,
       COUNT(*) OVER (
           ORDER BY id
           ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
           PATTERN (A+)
           DEFINE A AS val > 0
       ) as cnt
FROM rpr_planner;

-- ============================================================
-- 서브쿼리와 CTE 테스트
-- ============================================================
-- 서브쿼리 및 CTE와 함께 쓰는 RPR을 테스트한다

-- 서브쿼리 안의 RPR (FROM절)

SELECT * FROM (
    SELECT id, category, val,
           COUNT(*) OVER w as cnt
    FROM rpr_planner
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
) sub
WHERE cnt > 5;

-- WHERE절의 서브쿼리를 가진 RPR

SELECT id, category, val,
       COUNT(*) OVER w as cnt
FROM rpr_planner
WHERE val > (SELECT AVG(val) FROM rpr_planner)
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 50
);

-- RPR을 가진 CTE

WITH rpr_cte AS (
    SELECT id, category, val,
           COUNT(*) OVER w as cnt
    FROM rpr_planner
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
)
SELECT * FROM rpr_cte WHERE cnt > 5 ORDER BY id;

-- 여러 번 참조되는 CTE

WITH rpr_cte AS (
    SELECT id, category, val,
           COUNT(*) OVER w as cnt
    FROM rpr_planner
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
)
SELECT c1.id, c1.cnt, c2.cnt as cnt2
FROM rpr_cte c1
JOIN rpr_cte c2 ON c1.id = c2.id
ORDER BY c1.id;

-- 중첩된 CTE

WITH cte1 AS (
    SELECT id, category, val FROM rpr_planner WHERE val > 30
),
cte2 AS (
    SELECT id, category, val,
           COUNT(*) OVER w as cnt
    FROM cte1
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS val > 0
    )
)
SELECT * FROM cte2 ORDER BY id;

-- ============================================================
-- JOIN 테스트
-- ============================================================
-- JOIN 및 여러 테이블 참조와 함께 쓰는 RPR을 테스트한다

CREATE TABLE rpr_join1 (id INT, val1 INT);
CREATE TABLE rpr_join2 (id INT, val2 INT);

INSERT INTO rpr_join1 VALUES (1, 10), (2, 20), (3, 30), (4, 40), (5, 50);
INSERT INTO rpr_join2 VALUES (1, 100), (2, 200), (3, 300), (4, 400), (5, 500);

-- INNER JOIN 뒤의 RPR

SELECT t1.id, t1.val1, t2.val2,
       COUNT(*) OVER w as cnt
FROM rpr_join1 t1
INNER JOIN rpr_join2 t2 ON t1.id = t2.id
WINDOW w AS (
    ORDER BY t1.id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val1 + val2 > 100
);

-- LEFT JOIN 뒤의 RPR

SELECT t1.id, t1.val1, t2.val2,
       COUNT(*) OVER w as cnt
FROM rpr_join1 t1
LEFT JOIN rpr_join2 t2 ON t1.id = t2.id
WINDOW w AS (
    ORDER BY t1.id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val1 > 0
);

-- DEFINE 안에서 여러 테이블을 쓰는 RPR

SELECT t1.id, t1.val1, t2.val2,
       COUNT(*) OVER w as cnt
FROM rpr_join1 t1
INNER JOIN rpr_join2 t2 ON t1.id = t2.id
WINDOW w AS (
    ORDER BY t1.id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ B)
    DEFINE A AS val1 > 20,
           B AS val2 > 200
);

-- CROSS JOIN 뒤의 RPR

SELECT t1.id as id1, t2.id as id2, t1.val1, t2.val2,
       COUNT(*) OVER w as cnt
FROM rpr_join1 t1
CROSS JOIN rpr_join2 t2
WHERE t1.id <= 2 AND t2.id <= 2
WINDOW w AS (
    ORDER BY t1.id, t2.id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val1 + val2 > 0
);

-- RPR을 쓰는 셀프 조인

SELECT id, val1, val1_next,
       COUNT(*) OVER w as cnt
FROM (SELECT a.id, a.val1, b.val1 as val1_next
      FROM rpr_join1 a
      INNER JOIN rpr_join1 b ON a.id + 1 = b.id) sub
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (X+)
    DEFINE X AS val1 < val1_next
);

DROP TABLE rpr_join1, rpr_join2;

-- 타입이 일치하지 않는 USING 병합 열은 예전에는 상대편의 풀업된 상수가 계획
-- 시점에 내비게이션 인자로 접혀 들어가게 만들곤 했다.
CREATE TABLE rpr_join4 (k bigint);
INSERT INTO rpr_join4 VALUES (10);

SELECT count(*) OVER w AS cnt
FROM (SELECT 10 AS k) a LEFT JOIN rpr_join4 USING (k)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS PREV(k / 0) > 0
);

-- 같은 상황이지만, 상수 서브쿼리를 보존된(오른쪽) 쪽에 둔 RIGHT JOIN이다.
SELECT count(*) OVER w AS cnt
FROM rpr_join4 RIGHT JOIN (SELECT 10 AS k) a USING (k)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS PREV(k / 0) > 0
);

DROP TABLE rpr_join4;

-- 실제 행마다 다른 데이터를 가진 같은 모양으로, 내비게이션이 여전히 각 행의
-- 고유한 값을 보는지 확인한다.
CREATE TABLE rpr_join5 (k int, v int);
INSERT INTO rpr_join5 VALUES (1, 10), (2, 0), (3, 5);
CREATE TABLE rpr_join6 (k bigint, w int);
INSERT INTO rpr_join6 VALUES (1, 1), (2, 1), (3, 1);

SELECT k, v, cnt
FROM (SELECT k, v, count(*) OVER win AS cnt
      FROM rpr_join5 LEFT JOIN rpr_join6 USING (k)
      WINDOW win AS (
          ORDER BY k
          ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
          PATTERN (A+)
          DEFINE A AS PREV(v) IS NOT NULL
      )) s
ORDER BY k;

DROP TABLE rpr_join5, rpr_join6;

-- 양쪽 typmod가 다른 USING 열을 읽는 DEFINE 절.  병합된 열은 조인 별칭 Var로
-- 남고, 풀업은 그 joinaliasvars 항목을 자명하지 않은 표현식으로 남기며, 외부
-- 조인의 nullingrels는 그것을 PlaceHolderVar 로 감싼다.  타깃 리스트 사본과
-- DEFINE 사본은 서로 다른 호출로 감싸지므로 phid가 다르고 equal()은 그것들을
-- 같다고 매칭하지 않는다 -- 윈도우 입력은 DEFINE 절 자신의 PlaceHolderVar 를
-- 갖고 있어야 한다.
CREATE TABLE rpr_phv_src (n int);
CREATE TABLE rpr_phv_dim (c varchar(10), tdate date);
CREATE TABLE rpr_phv_out (k varchar);
INSERT INTO rpr_phv_src VALUES (2), (4);
INSERT INTO rpr_phv_dim VALUES ('zz', '2024-01-01'), ('zzzz', '2024-01-02');
INSERT INTO rpr_phv_out VALUES ('zz'), ('zzzz');

SELECT j.c, j.tdate, count(*) OVER w AS cnt
FROM rpr_phv_out o1
     LEFT JOIN ( (SELECT n, repeat('z', n)::varchar(5) AS c FROM rpr_phv_src) s
                 JOIN rpr_phv_dim USING (c) ) j
     ON o1.k = j.c
WINDOW w AS (ORDER BY j.tdate
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL PATTERN (p q+)
             DEFINE p AS TRUE, q AS c > '');

-- 그 위에 조인 단계를 하나 더 올린 같은 상황.  윈도우 입력에 도달하는
-- 것만으로는 충분하지 않다: 중간 조인은 그 위의 무언가가 필요하다고 선언한
-- 것만 출력하므로, DEFINE 절이 읽는 것도 타깃 리스트 자신의 열들처럼 relation
-- 0 에서 필요하다고 표시되어야 한다.
SELECT j.c, j.tdate, count(*) OVER w AS cnt
FROM rpr_phv_out o1
     LEFT JOIN rpr_phv_out o2 ON o1.k = o2.k
     LEFT JOIN ( (SELECT n, repeat('z', n)::varchar(5) AS c FROM rpr_phv_src) s
                 JOIN rpr_phv_dim USING (c) ) j
     ON o2.k = j.c
WINDOW w AS (ORDER BY j.tdate
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL PATTERN (p q+)
             DEFINE p AS TRUE, q AS c > '');

-- 대조군: USING의 양쪽이 같은 typmod이면 병합된 열은 한쪽의 평범한 Var가 되고,
-- PlaceHolderVar 는 만들어지지 않으며, 위의 두 모양 어느 것도 필요하지 않다.
SELECT j.c, j.tdate, count(*) OVER w AS cnt
FROM rpr_phv_out o1
     LEFT JOIN rpr_phv_out o2 ON o1.k = o2.k
     LEFT JOIN ( (SELECT n, repeat('z', n)::varchar(10) AS c
                  FROM rpr_phv_src) s
                 JOIN rpr_phv_dim USING (c) ) j
     ON o2.k = j.c
WINDOW w AS (ORDER BY j.tdate
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             INITIAL PATTERN (p q+)
             DEFINE p AS TRUE, q AS c > '');

DROP TABLE rpr_phv_src, rpr_phv_dim, rpr_phv_out;

-- 윈도우 함수를 이름으로 갖지 않는 WINDOW 절은 결코 실행되지 않으므로,
-- build_base_rel_tlists()가 그것이 읽는 것을 relation 0 에서 필요하다고
-- 표시하기 전에 그 DEFINE 절은 비워진다.  그렇지 않으면 외부 조인이 제거되지
-- 못하게 막을 것이다.  아래 세 계획이 바로 그 단언이다: WINDOW절 없음, 평범한
-- 절 하나, 행 패턴 절 하나 모두 똑같이 조인을 잃는다.
CREATE TABLE rpr_jr (id int, v int);
CREATE TABLE rpr_jr_u (id int PRIMARY KEY, uval int);
INSERT INTO rpr_jr SELECT g, g * 10 FROM generate_series(1, 5) g;
INSERT INTO rpr_jr_u SELECT g, g * 100 FROM generate_series(1, 5) g;

EXPLAIN (COSTS OFF)
SELECT t.id FROM rpr_jr t LEFT JOIN rpr_jr_u u ON t.id = u.id;

EXPLAIN (COSTS OFF)
SELECT t.id FROM rpr_jr t LEFT JOIN rpr_jr_u u ON t.id = u.id
WINDOW w AS (ORDER BY t.id);

EXPLAIN (COSTS OFF)
SELECT t.id FROM rpr_jr t LEFT JOIN rpr_jr_u u ON t.id = u.id
WINDOW w AS (ORDER BY t.id
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (A B+) DEFINE B AS uval > PREV(uval));

DROP TABLE rpr_jr, rpr_jr_u;

-- ============================================================
-- 복합 표현식 테스트
-- ============================================================
-- 복합적인 타깃 리스트 표현식을 테스트한다

CREATE TABLE rpr_target (id INT, val INT);
INSERT INTO rpr_target VALUES (1, 10), (2, 20), (3, 30), (4, 40), (5, 50);

-- 타깃 리스트 안의 표현식

SELECT id,
       val * 2 as doubled,
       val + 10 as added,
       COUNT(*) OVER w as cnt
FROM rpr_target
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 타깃 리스트 안의 CASE 표현식

SELECT id, val,
       CASE
           WHEN val < 30 THEN 'low'
           WHEN val < 50 THEN 'medium'
           ELSE 'high'
       END as category,
       COUNT(*) OVER w as cnt
FROM rpr_target
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 타깃 리스트 안의 서브쿼리

SELECT id, val,
       (SELECT MAX(val) FROM rpr_target) as max_val,
       COUNT(*) OVER w as cnt
FROM rpr_target
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 타깃 리스트 안의 함수 호출

SELECT id, val,
       COALESCE(val, 0) as coalesced,
       ABS(val - 30) as distance,
       COUNT(*) OVER w as cnt
FROM rpr_target
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 열 별칭과 참조

SELECT id as row_id,
       val as value,
       COUNT(*) OVER w as cnt
FROM rpr_target
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

DROP TABLE rpr_target;

-- ============================================================
-- 집합 연산 테스트
-- ============================================================
-- UNION, INTERSECT, EXCEPT와 함께 쓰는 RPR을 테스트한다

CREATE TABLE rpr_set1 (id INT, val INT);
CREATE TABLE rpr_set2 (id INT, val INT);

INSERT INTO rpr_set1 VALUES (1, 10), (2, 20), (3, 30);
INSERT INTO rpr_set2 VALUES (2, 20), (3, 30), (4, 40);

-- RPR을 쓰는 UNION

(SELECT id, val, COUNT(*) OVER w as cnt
 FROM rpr_set1
 WINDOW w AS (
     ORDER BY id
     ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
     PATTERN (A+)
     DEFINE A AS val > 0
 ))
UNION
(SELECT id, val, COUNT(*) OVER w as cnt
 FROM rpr_set2
 WINDOW w AS (
     ORDER BY id
     ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
     PATTERN (A+)
     DEFINE A AS val > 0
 ))
ORDER BY id;

-- RPR을 쓰는 UNION ALL

(SELECT id, val, COUNT(*) OVER w as cnt
 FROM rpr_set1
 WINDOW w AS (
     ORDER BY id
     ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
     PATTERN (A+)
     DEFINE A AS val > 0
 ))
UNION ALL
(SELECT id, val, COUNT(*) OVER w as cnt
 FROM rpr_set2
 WINDOW w AS (
     ORDER BY id
     ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
     PATTERN (A+)
     DEFINE A AS val > 0
 ))
ORDER BY id, val;

-- RPR을 쓰는 INTERSECT

(SELECT id, val, COUNT(*) OVER w as cnt
 FROM rpr_set1
 WINDOW w AS (
     ORDER BY id
     ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
     PATTERN (A+)
     DEFINE A AS val > 0
 ))
INTERSECT
(SELECT id, val, COUNT(*) OVER w as cnt
 FROM rpr_set2
 WINDOW w AS (
     ORDER BY id
     ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
     PATTERN (A+)
     DEFINE A AS val > 0
 ))
ORDER BY id;

-- RPR을 쓰는 EXCEPT

(SELECT id, val, COUNT(*) OVER w as cnt
 FROM rpr_set1
 WINDOW w AS (
     ORDER BY id
     ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
     PATTERN (A+)
     DEFINE A AS val > 0
 ))
EXCEPT
(SELECT id, val, COUNT(*) OVER w as cnt
 FROM rpr_set2
 WINDOW w AS (
     ORDER BY id
     ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
     PATTERN (A+)
     DEFINE A AS val > 0
 ))
ORDER BY id;

DROP TABLE rpr_set1, rpr_set2;

-- ============================================================
-- 정렬과 그룹화 테스트
-- ============================================================
-- 정렬 및 그룹화와의 RPR 상호작용을 테스트한다

CREATE TABLE rpr_sort (id INT, category VARCHAR(10), val INT);
INSERT INTO rpr_sort VALUES
    (1, 'A', 30), (2, 'B', 20), (3, 'A', 10),
    (4, 'B', 40), (5, 'A', 50), (6, 'B', 60);

-- GROUP BY를 쓰는 RPR (DEFINE 안의 집계 -> GROUP BY 상호작용 전에 ERROR)

SELECT category,
       COUNT(*) as group_cnt,
       MAX(val) as max_val,
       COUNT(*) OVER w as window_cnt
FROM rpr_sort
GROUP BY category
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS COUNT(*) > 0
);

-- HAVING을 쓰는 RPR (같은 DEFINE-안-집계 오류)

SELECT category,
       COUNT(*) as group_cnt,
       COUNT(*) OVER w as window_cnt
FROM rpr_sort
GROUP BY category
HAVING COUNT(*) > 2
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS COUNT(*) > 0
);

-- DISTINCT를 쓰는 RPR

SELECT DISTINCT category,
       COUNT(*) OVER w as cnt
FROM rpr_sort
WINDOW w AS (
    PARTITION BY category
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
)
ORDER BY category;

-- ORDER BY를 쓰는 RPR (윈도우 ORDER BY와는 다름)

SELECT id, category, val,
       COUNT(*) OVER w as cnt
FROM rpr_sort
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
)
ORDER BY val DESC;

-- LIMIT과 OFFSET을 쓰는 RPR

SELECT id, category, val,
       COUNT(*) OVER w as cnt
FROM rpr_sort
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
)
ORDER BY id
LIMIT 3 OFFSET 1;

-- ------------------------------------------------------------
-- 그룹화된 입력에 대한 RPR
-- ------------------------------------------------------------
-- DEFINE 절은 WindowClause 중에서 유일하게 자신만의 표현식 트리를 갖는
-- 부분이므로, parseCheckAggregates()는 타깃 리스트의 그룹화된 열과는 별도로 그
-- 절의 그룹화된 열을 대입해야 한다.  아래 테스트들은 그 대입에 도달하는 그룹화
-- 모양들과, 그룹화 집합이 패턴이 읽는 열을 null로 만들 때 각각 무엇을
-- 반환하는지를 고정한다.

CREATE TABLE rpr_grp (id int PRIMARY KEY, category text, val int);
INSERT INTO rpr_grp VALUES (1, 'A', 10), (2, 'B', 20);

-- 그룹화된 입력도 동작한다; 패턴은 그룹화된 행에 대해 매치된다
SELECT category, sum(val) AS total, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY category
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS category IS NOT NULL)
ORDER BY category;

-- 그룹화 열에 대한 내비게이션
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY category
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B*)
    DEFINE B AS category > PREV(category))
ORDER BY category;

-- GROUP BY ()는 RTE_GROUP 을 만들지 않으므로, DEFINE 절이 이름으로 쓸 그룹화된
-- 열도 없고 달라질 것도 없다
SELECT count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY ()
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS true);

-- 단일 그룹화 집합은 평범한 GROUP BY로 축소되며 그 열을 null로 만들 수 없다
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY GROUPING SETS ((category))
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL)
ORDER BY category;

-- 중복된 집합은 그 열을 모든 집합에 남기므로 결코 null이 되지 않는다
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY GROUPING SETS ((category), (category))
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL)
ORDER BY category;

-- 열 참조를 전혀 담지 않은 DEFINE 절을 가진 ROLLUP
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS true)
ORDER BY category NULLS LAST;

-- DEFINE 절은 모든 그룹화 집합이 포함하는 열만 이름으로 쓰므로, gset_common 이
-- 그것을 포괄하고 varnullingrels는 붙지 않는다
SELECT category, val, count(*) OVER w AS cnt
FROM rpr_sort
WHERE val < 30
GROUP BY category, ROLLUP(val)
WINDOW w AS (
    ORDER BY category, val
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL)
ORDER BY category, val NULLS LAST;

-- 윈도우 자신의 PARTITION BY와 ORDER BY는 타깃 리스트를 참조하므로, null이 될
-- 수 있는 그룹화 열도 손상 없이 그곳에 도달한다
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w AS (
    PARTITION BY category
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS true)
ORDER BY category NULLS LAST;

-- GROUP BY 없는 집계 쿼리는 그룹화된 행 하나를 만든다
SELECT count(*) OVER w AS cnt
FROM rpr_sort
HAVING count(*) > 0
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS true);

SELECT count(*) OVER w AS cnt, sum(val) AS total
FROM rpr_sort
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS true);

-- HAVING과 함께 쓰는 GROUP BY
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY category
HAVING count(*) > 1
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL)
ORDER BY category;

-- 평범한 Var가 아닌 그룹화 키는, 평범한 Var 그룹화 키를 이름으로 쓰는 DEFINE
-- 절을 방해하지 않는다
SELECT category, val + 1 AS bumped, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY val + 1, category
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL)
ORDER BY category;

-- 기본 키로 그룹화하면 종속된 열들이 드러난다
SELECT id, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY id
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS val > 0)
ORDER BY id;

-- 집계는 윈도우의 ORDER BY에서 쓸 수 있으며, 그것이 바로 패턴이 매치를
-- 진행하는 순서다: sum(val) 내림차순은 B를 먼저 두므로 탐욕적 매치는 거기서
-- 시작한다.  대신 category로 정렬했다면 A에서 시작했을 것이다.
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY category
WINDOW w AS (
    ORDER BY sum(val) DESC
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS category IS NOT NULL)
ORDER BY category;

-- 서브쿼리 안의 그룹화는 바깥의 RPR 윈도우를 건드리지 않는다
SELECT category, total, count(*) OVER w AS cnt
FROM (SELECT category, sum(val) AS total FROM rpr_sort GROUP BY category) s
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B*)
    DEFINE B AS total > PREV(total))
ORDER BY category;

-- 그룹화된 입력에 대한 뷰는 왕복한다
CREATE VIEW rpr_grp_v AS
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY category
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS category IS NOT NULL);

SELECT pg_get_viewdef('rpr_grp_v'::regclass, true);
SELECT * FROM rpr_grp_v ORDER BY category;
DROP VIEW rpr_grp_v;

-- ROLLUP이고, null로 만들 수 있는 열을 이름으로 쓰는 DEFINE 절이다.  그룹화
-- 단계의 NULL이 조건절에 도달하여 false가 되므로, total 행은 매치되지 않는다.
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL);

-- 여러 그룹화된 행에 걸친 매치이므로, 축소된 프레임은 현재 행 하나가 아니다:
-- A+는 탐욕적이며 ROLLUP이 null로 만든 행에서 멈춘다.
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS category >= 'A')
ORDER BY category NULLS LAST;

-- CUBE에 대해서도 마찬가지다
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY CUBE(category)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL);

-- 빈 집합을 포함하는 명시적 집합 목록에 대해서도 마찬가지다
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY GROUPING SETS ((category), ())
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL);

-- 두 번째 집합이 단순히 그 열을 생략할 때도 마찬가지다
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY GROUPING SETS ((category), (val))
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL);

-- ROLLUP이 null로 만들 수 있는 val을 이름으로 쓰는 경우도 위의 category와 같은
-- 방식으로 동작한다: null이 된 행은 매치되지 않는다
SELECT category, val, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY category, ROLLUP(val)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS val > 0);

-- DEFINE 절 안의 내비게이션도 그룹화된 열을 같은 방식으로 읽는다
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B*)
    DEFINE B AS PREV(category) IS NOT NULL);

-- 복합 내비게이션에 대해서도 마찬가지다
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w AS (
    ORDER BY category
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B*)
    DEFINE B AS PREV(LAST(category)) IS NOT NULL);

-- 쿼리 수준을 한 단계 낮춰도 마찬가지다
SELECT * FROM (
    SELECT category, count(*) OVER w AS cnt
    FROM rpr_sort
    GROUP BY ROLLUP(category)
    WINDOW w AS (
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A)
        DEFINE A AS category IS NOT NULL)) s;

-- 그리고 뷰 정의에서도.  get_query_def()는 DEFINE 절의 GROUP Var도 타깃
-- 리스트와 마찬가지로 펼치므로, 디파스된 텍스트는 그룹화 단계가 아니라 열을
-- 이름으로 쓰고, 뷰는 재파싱된다.
CREATE VIEW rpr_grp_v2 AS
SELECT category, count(*) OVER w AS cnt
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL);

SELECT pg_get_viewdef('rpr_grp_v2'::regclass, true);
SELECT * FROM rpr_grp_v2 ORDER BY category NULLS LAST;
DROP VIEW rpr_grp_v2;

-- DEFINE 절은 GROUP BY 표현식을 그대로 표기할 수 있다.  플래너는 그 아래의
-- 열들을 따로 요구하는 대신, 윈도우 입력 타깃이 이미 통째로 계산해 둔
-- 표현식에서 멈춘다.  그룹화는 그 아래의 열을 이용할 수 있게 해주지 않기
-- 때문이다; DEFINE 사본은 그다음 그 같은 열을 대상으로 풀린다.
SELECT val + 1 AS bumped, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY val + 1
WINDOW w AS (
    ORDER BY val + 1
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS val + 1 > 0)
ORDER BY bumped;

-- GROUP BY도 그대로 표기하는 휘발성 표현식은 거부되지 않는다: DEFINE 사본은
-- GROUP Var가 되고, 패턴 매치는 표현식이 아니라 그룹화 단계가 계산한 값을 입력
-- 행마다 한 번씩 읽는다.  DEFINE 평가 횟수가 아니라 입력 행 수만큼 시퀀스가
-- 진행된다는 사실이 그것을 보여준다.
CREATE SEQUENCE rpr_grp_seq;
SELECT val, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY val, nextval('rpr_grp_seq')
WINDOW w AS (
    ORDER BY val
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS nextval('rpr_grp_seq') > 0)
ORDER BY val;
SELECT last_value = (SELECT count(*) FROM rpr_grp) AS once_per_row
FROM rpr_grp_seq;
DROP SEQUENCE rpr_grp_seq;

-- 함수 호출에 대해서도 마찬가지다
SELECT upper(category) AS u, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY upper(category)
WINDOW w AS (
    ORDER BY upper(category)
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS upper(category) = 'A')
ORDER BY u;

-- 캐스트에 대해서도 마찬가지다
SELECT val::text AS t, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY val::text
WINDOW w AS (
    ORDER BY val::text
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS val::text > '0')
ORDER BY t;

-- 그리고 인자를 같은 방식으로 읽는 내비게이션 연산을 거쳐서도 마찬가지다
SELECT val + 1 AS bumped, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY val + 1
WINDOW w AS (
    ORDER BY val + 1
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B*)
    DEFINE B AS PREV(val + 1) > 0)
ORDER BY bumped;

-- 그룹화 집합 아래에서도 마찬가지이며, 그 집합이 null로 만드는 행에서는
-- 조건절이 알 수 없음(unknown)이 되어 매치되지 않는다.
SELECT val + 1 AS bumped, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY ROLLUP(val + 1)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS val + 1 > 0);

-- DEFINE 절은 그룹화 없이도 윈도우 자신이 정렬 기준으로 쓰는 표현식을 그대로
-- 반복할 수 있다.  DEFINE 절이 읽는 맨 Var들을 윈도우 입력 타깃에 추가하는
-- 것이 이를 가능하게 만든다: ROW(val, 1) IS NOT NULL의 DEFINE 사본은 계획을
-- 세우기 전에 필드별 테스트로 쪼개지고, 그 분리가 남긴 맨 val은 윈도우가 정렬
-- 기준으로 쓰는 ROW(val, 1) 전체 옆에 별도로 입력에 추가된다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_grp
WINDOW w AS (
    ORDER BY ROW(val, 1)
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS ROW(val, 1) IS NOT NULL)
ORDER BY id;

-- ERROR: 맨 열은 다른 문제다; 표현식으로 그룹화한다고 해서 그 안의 열들을 따로
-- 이용할 수 있게 되는 것은 아니다
SELECT val + 1 AS bumped, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY val + 1
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS val > 0);

-- ERROR: 한 번도 그룹화되지 않은 열도 그룹화된 것처럼 보고된다
SELECT category, count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY category
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS val > 0);

-- 인라인 OVER (...)는 자신만의 윈도우 절을 가지며, 대입은 그곳에도 같은
-- 방식으로 도달한다
SELECT category,
       count(*) OVER (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                      PATTERN (A)
                      DEFINE A AS category IS NOT NULL) AS cnt
FROM rpr_sort
GROUP BY ROLLUP(category);

-- 대입은 첫 번째뿐 아니라 모든 윈도우 절을 방문한다.  여기서는 첫 윈도우가
-- 평범한 것이고 행 패턴은 두 번째에 있다.
SELECT category, count(*) OVER w1 AS plain, count(*) OVER w2 AS rpr
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w1 AS (ORDER BY category),
       w2 AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS category IS NOT NULL);

-- ERROR: 참조되지 않는 윈도우도 다른 것과 똑같이 대입되므로, 나중에 플래너가
-- 그 윈도우를 버리더라도 그 DEFINE 절은 여전히 그룹화되지 않은 열을 읽을
-- 수 없다
SELECT category
FROM rpr_sort
GROUP BY ROLLUP(category)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS val > 0);

-- 타입이 일치하는 내부 조인의 USING 열은 조인 별칭 Var가 아니라 그냥 왼쪽
-- 입력의 열이므로, 평범한 그룹화가 그것을 참조하는 DEFINE 절과 바로 매칭되고
-- 패턴은 손상 없이 그것을 읽는다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_grp JOIN rpr_sort USING (id)
GROUP BY id
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS id > 0)
ORDER BY id;

-- 같은 쿼리를 조인을 거쳐서, 패턴이 읽는 열을 null로 만들 수 있는 그룹화
-- 집합과 함께
SELECT id, count(*) OVER w AS cnt
FROM rpr_grp JOIN rpr_sort USING (id)
GROUP BY ROLLUP(id)
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS id > 0)
ORDER BY id;

-- FULL JOIN의 USING 열은 병합된 열이다 -- 양쪽 어느 하나가 아니라 둘에 대한
-- COALESCE다 -- 그래서 그것을 이름으로 쓰는 DEFINE 절은 조인 별칭 Var를
-- 가지며, flatten_join_alias_for_parser()만이 그것을 그룹화된 타깃 리스트와
-- 매칭할 수 있는 것으로 바꾼다.  위의 내부 조인들은 그 단계 없이도
-- 패턴에 도달한다.
SELECT id, count(*) OVER w AS cnt
FROM rpr_grp FULL JOIN rpr_sort USING (id)
GROUP BY ROLLUP(id)
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS id > 0)
ORDER BY id NULLS LAST;

-- 빈 집합만 담은 그룹화 집합 목록도 GROUP BY ()와 마찬가지로 RTE_GROUP 을
-- 만들지 않는다
SELECT count(*) OVER w AS cnt
FROM rpr_grp
GROUP BY GROUPING SETS (())
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE A AS true);

-- 조인 자신의 이름이 아니라 병합된 열의 COALESCE 전개로 표기된 GROUP BY,
-- 그리고 같은 열을 읽는 DEFINE: 트리 모양은 다르지만 두 표기는 같다고
-- 비교되어야 한다.
SELECT id + 1 AS b, count(*) OVER w AS cnt
FROM rpr_grp FULL JOIN rpr_sort USING (id)
GROUP BY COALESCE(rpr_grp.id, rpr_sort.id) + 1
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A) DEFINE A AS (id + 1) > 0)
ORDER BY 1;

-- 같은 구성을 뷰로: DEFINE 절은 그룹화가 계산한 양쪽짜리 COALESCE가 아니라
-- 평범한 조인 열로 디파스되어야 한다.  그러지 않으면 출력된 텍스트가
-- 재파싱되지 않는다.
CREATE VIEW rpr_fjcoal_v AS
SELECT COALESCE(rpr_grp.id, rpr_sort.id) + 1 AS idp1, count(*) OVER w AS cnt
FROM rpr_grp FULL JOIN rpr_sort USING (id)
GROUP BY COALESCE(rpr_grp.id, rpr_sort.id) + 1
WINDOW w AS (
    ORDER BY COALESCE(rpr_grp.id, rpr_sort.id) + 1
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS id + 1 > 0);

SELECT pg_get_viewdef('rpr_fjcoal_v'::regclass, true);
SELECT * FROM rpr_fjcoal_v ORDER BY 1;

-- 디파스된 정의는 동일한 뷰로 재파싱된다.
CREATE VIEW rpr_fjcoal_v2 AS
 SELECT COALESCE(rpr_grp.id, rpr_sort.id) + 1 AS idp1,
    count(*) OVER w AS cnt
   FROM rpr_grp
     FULL JOIN rpr_sort USING (id)
   GROUP BY (COALESCE(rpr_grp.id, rpr_sort.id) + 1)
   WINDOW w AS (ORDER BY (COALESCE(rpr_grp.id, rpr_sort.id) + 1) ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
   AFTER MATCH SKIP PAST LAST ROW
   INITIAL
   PATTERN (a+)
   DEFINE
   a AS (id + 1) > 0);

SELECT pg_get_viewdef('rpr_fjcoal_v2'::regclass, true) =
      pg_get_viewdef('rpr_fjcoal_v'::regclass, true) AS same_definition;

DROP VIEW rpr_fjcoal_v2;
DROP VIEW rpr_fjcoal_v;

DROP TABLE rpr_grp;

DROP TABLE rpr_sort;

-- SQL 함수 인라인화: DEFINE 안의 $1 은 query_tree_mutator 를 거쳐
-- substitute_actual_parameters_in_from 함수가 대입해야 한다.
CREATE TABLE rpr_srf_t (v int);
INSERT INTO rpr_srf_t SELECT generate_series(1, 5);

CREATE FUNCTION rpr_srf_inline(threshold int)
RETURNS TABLE (v int, cnt bigint)
LANGUAGE sql STABLE AS $$
    SELECT v::int, count(*) OVER w
    FROM rpr_srf_t
    WINDOW w AS (
        ORDER BY v
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS v > $1
    )
$$;

SELECT v, cnt FROM rpr_srf_inline(3) ORDER BY v;

DROP TABLE rpr_srf_t;
DROP FUNCTION rpr_srf_inline(int);

DROP TABLE rpr_planner;

-- 복합 GROUP BY 표현식을 읽는 DEFINE 절.  그룹화 후에는 그 표현식 자체만
-- 존재하므로, make_window_input_target()은 그것을 통째로 받아 멈춰야 한다: 그
-- 아래 Var를 요구하는 것은 그룹화 단계에 만들어 낼 수 없는 열을 요구하는 셈이
-- 된다.  Output 줄에 맨 a도 맨 b도 HashAggregate 위 어디에도 없이
-- "((a + b))"만 있는 것이 바로 그 단언이다.
CREATE TABLE rpr_gexp (a int, b int);
INSERT INTO rpr_gexp VALUES (1, 1), (2, 2), (3, 3), (4, 4);

SELECT a + b AS ab, count(*) OVER w AS c
FROM rpr_gexp
GROUP BY a + b
WINDOW w AS (ORDER BY a + b
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (X+) DEFINE X AS a + b > 2);

EXPLAIN (VERBOSE, COSTS OFF)
SELECT a + b AS ab, count(*) OVER w AS c
FROM rpr_gexp
GROUP BY a + b
WINDOW w AS (ORDER BY a + b
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (X+) DEFINE X AS a + b > 2);

-- 그룹화 표현식 아래로 내려가는 것은, 그룹화 후에 평가되는 다른 어떤 절에서도
-- 그렇듯 거부된다.
SELECT a + b AS ab, count(*) OVER w AS c
FROM rpr_gexp
GROUP BY a + b
WINDOW w AS (ORDER BY a + b
             ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
             PATTERN (X+) DEFINE X AS a > 2);

DROP TABLE rpr_gexp;

-- ============================================================
-- 스트레스 테스트
-- ============================================================
-- 경계 사례와 스트레스 시나리오

CREATE TABLE rpr_stress (id INT, val INT);
INSERT INTO rpr_stress SELECT i, i * 10 FROM generate_series(1, 20) i;

-- 윈도우가 많은 매우 긴 쿼리
SELECT id, val,
       COUNT(*) OVER w1 as cnt1,
       COUNT(*) OVER w2 as cnt2,
       COUNT(*) OVER w3 as cnt3
FROM rpr_stress
WINDOW w1 AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
),
w2 AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (B+)
    DEFINE B AS val > 50
),
w3 AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (C+)
    DEFINE C AS val > 100
);

-- RPR을 쓰는 깊이 중첩된 서브쿼리

SELECT * FROM (
    SELECT * FROM (
        SELECT * FROM (
            SELECT id, val,
                   COUNT(*) OVER w as cnt
            FROM rpr_stress
            WINDOW w AS (
                ORDER BY id
                ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                PATTERN (A+)
                DEFINE A AS val > 0
            )
        ) sub1
    ) sub2
) sub3
WHERE cnt > 10;

-- DEFINE 절 안의 복합 표현식

SELECT id, val,
       COUNT(*) OVER w as cnt
FROM rpr_stress
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+ B)
    DEFINE A AS (val % 3 = 0 OR val % 5 = 0),
           B AS (val * 2 > 100 AND val / 2 < 100)
);

-- 매치되는 행이 없는 윈도우

SELECT id, val,
       COUNT(*) OVER w as cnt
FROM rpr_stress
WHERE val > 1000  -- 매치되는 행 없음
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

-- 한 행짜리 윈도우

SELECT id, val,
       COUNT(*) OVER w as cnt
FROM rpr_stress
WHERE id = 10
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS val > 0
);

DROP TABLE rpr_stress;

-- ============================================================
-- 오류 한계 테스트
-- ============================================================
-- parse_rpr.c와 rpr.c의 오류 조건을 테스트한다

CREATE TABLE rpr_errors (id INT, val INT);
INSERT INTO rpr_errors VALUES (1, 10), (2, 20);

-- PATTERN에 없는 DEFINE 변수 (오류)
SELECT id, val, COUNT(*) OVER w FROM rpr_errors
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A)
    DEFINE
      B AS TRUE
);

-- 행 패턴 변수 개수 경계: 240 개 변수는 허용되고, 241 개는 거부된다.  varId 는
-- 1 바이트이고 상위 니블(0xF0-0xFF)은 제어 요소용으로 예약되어 있으므로
-- RPR_VARID_MAX 는 0xEF이며, 241 번째로 구별되는 변수는 그 예약된 범위에
-- 들어가게 된다.
-- 거부되는 사례는 PATTERN에만 V241 을 이름으로 쓴다. 이 한계는 DEFINE이 그것을
-- 이름으로 쓰든 말든 구별되는 PATTERN 변수 수를 세므로, V241 도 여전히
-- 세어지고 그것이 총합을 한계 너머로 밀어낸다.
-- 생성된 240 개 변수짜리 절이 예상 출력을 넘치게 만들지 않도록 ECHO를 끈다.
--   변수 240 개 -> 최대, 허용됨.
--   변수 241 개 -> 최대 초과, 거부됨.
\set ECHO none
SELECT format($$SELECT COUNT(*) OVER w FROM rpr_errors
  WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  PATTERN (%s) DEFINE %s)$$,
  (SELECT string_agg('V' || i, ' ' ORDER BY i)
     FROM generate_series(1, 240) i),
  (SELECT string_agg('V' || i || ' AS val > 0', ', ' ORDER BY i)
     FROM generate_series(1, 240) i)) \gexec
SELECT format($$SELECT COUNT(*) OVER w FROM rpr_errors
  WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  PATTERN (%s) DEFINE %s)$$,
  (SELECT string_agg('V' || i, ' ' ORDER BY i)
     FROM generate_series(1, 241) i),
  (SELECT string_agg('V' || i || ' AS val > 0', ', ' ORDER BY i)
     FROM generate_series(1, 240) i)) \gexec
\set ECHO all

-- 패턴 중첩 깊이 경계: 254 단계는 허용되고, 255 단계는 거부된다.  소극적
-- 수량자는 수량자 곱셈의 대상이 아니므로, 중첩은 최적화에서 살아남아 여전히
-- 깊이 검사에 도달한다.  생성된 깊이 중첩 패턴이 예상 출력을 넘치게 만들지
-- 않도록 ECHO를 끈다.
--   중첩된 GROUP{3,7}?  254 개 -> 깊이 254 = 최대, 허용됨.  중첩된 GROUP{3,7}?
--   255 개 -> 깊이 255 > 최대, 거부됨.
\set ECHO none
SELECT format($$SELECT id, val, COUNT(*) OVER w FROM rpr_errors
  WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  PATTERN (%sA{3,7}?%s) DEFINE A AS val > 0)$$,
  repeat('(', 254), repeat('){3,7}?', 254)) \gexec
SELECT format($$SELECT id, val, COUNT(*) OVER w FROM rpr_errors
  WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  PATTERN (%sA{3,7}?%s) DEFINE A AS val > 0)$$,
  repeat('(', 255), repeat('){3,7}?', 255)) \gexec
\set ECHO all

DROP TABLE rpr_errors;

-- ============================================================
-- 기본 패턴 매칭
-- ============================================================

-- A? (선택적, 탐욕적)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A?)
    DEFINE A AS val > 50
);

-- A{2} (정확한 개수)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{2})
    DEFINE A AS val <= 50
);

-- A{1,3} (한계 있는 범위, 탐욕적)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A{1,3})
    DEFINE A AS val <= 50
);

-- A | B (단순 교대)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A | B)
    DEFINE A AS val <= 30, B AS val > 70
);

-- A | B | C (3 방향 교대)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A | B | C)
    DEFINE A AS val <= 20, B AS val BETWEEN 40 AND 60, C AS val > 80
);

-- A B C (연결)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B C)
    DEFINE A AS val <= 30, B AS val BETWEEN 31 AND 60, C AS val > 60
);

-- A B? C (선택적 중간)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B? C)
    DEFINE A AS val <= 30, B AS val BETWEEN 31 AND 60, C AS val > 60
);

-- (A B)+ (그룹화된 수량자)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A B)+)
    DEFINE A AS val <= 50, B AS val > 50
);

-- (A | B)+ C (수량자를 가진 교대)
SELECT id, val, count(*) OVER w AS c
FROM rpr_plan
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A | B)+ C)
    DEFINE A AS val <= 30, B AS val BETWEEN 31 AND 60, C AS val > 80
);

-- (A+ | (A | B)+)* - 수량자가 붙은 그룹 안의 중첩 교대
SELECT id, flags, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM (VALUES
    (1, ARRAY['A', 'B']),
    (2, ARRAY['B']),
    (3, ARRAY['C'])
) AS t(id, flags)
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN ((A+ | (A | B)+)*)
    DEFINE
        A AS 'A' = ANY(flags),
        B AS 'B' = ANY(flags)
);

-- ============================================================
-- 병리적 패턴
-- ============================================================
-- 최적화기가 축약하는 중첩된 무한 수량자들.

-- (A*)* - 중첩된 무한 (A*로 최적화됨)
SELECT v, count(*) OVER w AS c
FROM (SELECT generate_series(1, 5) v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((A*)*)
    DEFINE A AS TRUE
);

-- (A*)+ - 안쪽이 nullable (A*로 최적화됨)
SELECT v, count(*) OVER w AS c
FROM (SELECT generate_series(1, 5) v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((A*)+)
    DEFINE A AS TRUE
);

-- (A+)* - 바깥이 nullable (A*로 최적화됨)
SELECT v, count(*) OVER w AS c
FROM (SELECT generate_series(1, 5) v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((A+)*)
    DEFINE A AS TRUE
);

-- (A+)+ - 둘 다 매치를 요구 (A+로 최적화됨)
SELECT v, count(*) OVER w AS c
FROM (SELECT generate_series(1, 5) v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((A+)+)
    DEFINE A AS TRUE
);

-- (((A)*)*)*  - 삼중 중첩 (A*로 최적화됨)
SELECT v, count(*) OVER w AS c
FROM (SELECT generate_series(1, 3) v)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    INITIAL
    PATTERN ((((A)*)*)*)
    DEFINE A AS TRUE
);

-- 교대를 포함한 선택적 그룹: A ((B | C) (D | E))* F?
-- A만 매치될 때, * 그룹은 0 번 매치하고 F?도 0 번 매치한다
SELECT id, val, match_len
FROM (SELECT id, val,
             COUNT(*) OVER w AS match_len
      FROM (VALUES (1, 1), (2, 99)) AS t(id, val)
      WINDOW w AS (
          ORDER BY id
          ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
          AFTER MATCH SKIP PAST LAST ROW
          PATTERN (A ((B | C) (D | E))* F?)
          DEFINE A AS val = 1,
                 B AS val = 2, C AS val = 3,
                 D AS val = 4, E AS val = 5,
                 F AS val = 6
      )
) s;

DROP TABLE rpr_plan;
