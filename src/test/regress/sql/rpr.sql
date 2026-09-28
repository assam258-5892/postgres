--
-- 행 패턴 인식(RPR) 테스트: WINDOW 절 통합과 가상의 주가 데이터를 사용한
-- 시나리오 테스트.
--
-- 파서/플래너 테스트: rpr_base.sql
-- NFA 엔진 테스트: rpr_nfa.sql
-- EXPLAIN 통계 테스트: rpr_explain.sql
--

\getenv abs_srcdir PG_ABS_SRCDIR

-- RPR 패턴 매칭 테스트용 가상 주가 데이터
CREATE TABLE rpr_stock (
       part_id integer,
       rn      integer,
       price   numeric(10,3),
       volume  bigint,
       open    numeric(10,3),
       low     numeric(10,3),
       high    numeric(10,3)
);

\set filename :abs_srcdir '/data/stock.data'
COPY rpr_stock FROM :'filename';
ANALYZE rpr_stock;

CREATE TEMP TABLE rpr_price (company TEXT, tdate DATE, price INTEGER);
INSERT INTO rpr_price VALUES
('company1', '2023-07-01', 100), ('company1', '2023-07-02', 200),
('company1', '2023-07-03', 150), ('company1', '2023-07-04', 140),
('company1', '2023-07-05', 150), ('company1', '2023-07-06', 90),
('company1', '2023-07-07', 110), ('company1', '2023-07-08', 130),
('company1', '2023-07-09', 120), ('company1', '2023-07-10', 130),
('company2', '2023-07-01', 50), ('company2', '2023-07-02', 2000),
('company2', '2023-07-03', 1500), ('company2', '2023-07-04', 1400),
('company2', '2023-07-05', 1500), ('company2', '2023-07-06', 60),
('company2', '2023-07-07', 1100), ('company2', '2023-07-08', 1300),
('company2', '2023-07-09', 1200), ('company2', '2023-07-10', 1300);

SELECT * FROM rpr_price;

--
-- PREV/NEXT를 사용한 기본 패턴 매칭
--

-- PREV를 사용하는 기본 테스트
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w,
 nth_value(tdate, 2) OVER w AS nth_second
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UP+ DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- PREV를 사용하는 기본 테스트. UP이 두 번 나타난다
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w,
 nth_value(tdate, 2) OVER w AS nth_second
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UP+ DOWN+ UP+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- PREV를 사용하는 기본 테스트. '*'를 사용한다
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w,
 nth_value(tdate, 2) OVER w AS nth_second
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UP* DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- PREV를 사용하는 기본 테스트. '?'를 사용한다
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w,
 nth_value(tdate, 2) OVER w AS nth_second
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UP? DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- 시퀀스와 함께 교대(|)를 사용하는 테스트
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START (UP | DOWN))
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- 그룹 수량자와 함께 교대(|)를 사용하는 테스트
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START (UP | DOWN)+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- 중첩 교대를 사용하는 테스트
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START ((UP DOWN) | FLAT)+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price),
  FLAT AS price = PREV(price)
);

-- 수량자가 있는 그룹을 사용하는 테스트
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN ((UP DOWN)+)
 DEFINE
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- 상대적 PREV가 아니라 절대 임계값을 사용하는 테스트
-- HIGH: price > 150, LOW: price < 100, MID: 중립 구간
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (LOW MID* HIGH)
 DEFINE
  LOW AS price < 100,
  MID AS price >= 100 AND price <= 150,
  HIGH AS price > 150
);

-- 교대가 있는 임계값 기반 패턴 테스트
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (LOW (MID | HIGH)+)
 DEFINE
  LOW AS price < 100,
  MID AS price >= 100 AND price <= 150,
  HIGH AS price > 150
);

-- 고정 길이 패턴의 기본 테스트 (A A A = 정확히 3)
SELECT company, tdate, price, count(*) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (A A A)
 DEFINE
  A AS price >= 140 AND price <= 150
);

-- {n} 수량자를 사용하는 테스트 (A A A는 A{3}으로 최적화되어야 한다)
SELECT company, tdate, price, count(*) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (A{3})
 DEFINE
  A AS price >= 140 AND price <= 150
);

-- {n,} 수량자를 사용하는 테스트 (2 이상)
SELECT company, tdate, price, count(*) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (A{2,})
 DEFINE
  A AS price > 100
);

-- {n,m} 수량자를 사용하는 테스트 (2~4)
SELECT company, tdate, price, count(*) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (A{2,4})
 DEFINE
  A AS price > 100
);

-- bounded 수량자를 사용한 접두/접미 병합 최적화 테스트
-- 패턴 A B (A B){1,2} A B는 (A B){3,4}로 최적화되어야 한다
CREATE TEMP TABLE rpr_ab_pairs (id int, val text);
INSERT INTO rpr_ab_pairs VALUES
  (1,'A'),(2,'B'),
  (3,'A'),(4,'B'),
  (5,'A'),(6,'B'),
  (7,'A'),(8,'B'),
  (9,'X');
SELECT id, val, count(*) OVER w AS match_count
FROM rpr_ab_pairs
WINDOW w AS (
  ORDER BY id
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  AFTER MATCH SKIP TO NEXT ROW
  INITIAL
  PATTERN (A B (A B){1,2} A B)
  DEFINE
    A AS val = 'A',
    B AS val = 'B'
);
DROP TABLE rpr_ab_pairs;

-- last_value()는 일관되게 유지되어야 한다
SELECT company, tdate, price, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UP+ DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- DEFINE에서 "START"를 생략해도, 명세에 따라 "START AS TRUE"가 암묵적으로
-- 정의되므로 문제없다.
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w,
 nth_value(tdate, 2) OVER w AS nth_second
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UP+ DOWN+)
 DEFINE
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- 첫 번째 행은 100 이하로 시작한다
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (LOWPRICE UP+ DOWN+)
 DEFINE
  LOWPRICE AS price <= 100,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- 두 번째 행은 120% 상승한다
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (LOWPRICE UP+ DOWN+)
 DEFINE
  LOWPRICE AS price <= 100,
  UP AS price > PREV(price) * 1.2,
  DOWN AS price < PREV(price)
);

-- NEXT를 사용한다
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UPDOWN)
 DEFINE
  START AS TRUE,
  UPDOWN AS price > PREV(price) AND price > NEXT(price)
);

-- AFTER MATCH SKIP TO NEXT ROW을 사용한다 (위와 같은 패턴이며,
-- 매치 길이가 항상 2 이므로 결과는 SKIP PAST LAST ROW와 동일하다.
-- SKIP TO NEXT ROW의 고유한 효과는 백트래킹 절에서 테스트한다.)
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP TO NEXT ROW
 INITIAL
 PATTERN (START UPDOWN)
 DEFINE
  START AS TRUE,
  UPDOWN AS price > PREV(price) AND price > NEXT(price)
);

-- 파티션의 첫 행에서 PREV는 NULL을 반환한다 (가져올 이전 행이 없음)
SELECT company, tdate, price, count(*) OVER w
FROM rpr_price
WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 PATTERN (BOUNDARY REST+)
 DEFINE
  BOUNDARY AS PREV(price) IS NULL,
  REST AS PREV(price) IS NOT NULL
);

-- 파티션의 마지막 행에서 NEXT는 NULL을 반환한다 (가져올 다음 행이 없음)
SELECT company, tdate, price, count(*) OVER w
FROM rpr_price
WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (A+ BOUNDARY)
 DEFINE
  A AS NEXT(price) IS NOT NULL,
  BOUNDARY AS NEXT(price) IS NULL
);

-- DESC 순서: PREV는 더 나중 날짜의 행을 가리킨다
SELECT company, tdate, price, count(*) OVER w
FROM rpr_price
WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate DESC
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (START DOWN+ UP+)
 DEFINE
  START AS TRUE,
  DOWN AS price < PREV(price),
  UP AS price > PREV(price)
);

-- 크기가 서로 다른 여러 파티션
WITH multi_part AS (
 SELECT * FROM (VALUES
  ('a', 1, 10), ('a', 2, 20), ('a', 3, 15),
  ('b', 1, 5),
  ('c', 1, 100), ('c', 2, 200), ('c', 3, 150), ('c', 4, 140), ('c', 5, 300)
 ) AS t(grp, id, val)
)
SELECT grp, id, val, count(*) OVER w
FROM multi_part
WINDOW w AS (
 PARTITION BY grp
 ORDER BY id
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (A B+)
 DEFINE
  A AS val <= NEXT(val),
  B AS val > PREV(val) OR val < PREV(val)
);

-- FLOAT/NUMERIC DEFINE 조건
WITH float_data AS (
 SELECT * FROM (VALUES
  (1, 1.0::float8), (2, 1.5), (3, 1.4999), (4, 1.50001), (5, 0.1)
 ) AS t(id, val)
)
SELECT id, val, count(*) OVER w
FROM float_data
WINDOW w AS (
 ORDER BY id
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (A B+)
 DEFINE
  A AS TRUE,
  B AS val > PREV(val) * 0.99
);

--
-- 오류 사례: PREV/NEXT 사용 제약
--

-- 중첩된 PREV
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS price > PREV(PREV(price))
);

-- 중첩된 NEXT
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS price > NEXT(NEXT(price))
);

-- NEXT 안에 중첩된 PREV
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS price > NEXT(PREV(price))
);

-- NEXT 안의 식 안에 중첩된 PREV
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS price > NEXT(price * PREV(price))
);

-- 삼중 중첩: 가장 바깥쪽 PREV에서 오류가 보고된다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS price > PREV(PREV(PREV(price)))
);

-- PREV/NEXT 인자에 컬럼 참조가 없음
-- PREV(1): 상수뿐이며 컬럼 참조가 없다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(1) > 0
);

-- NEXT(1 + 2): 상수 식이며 컬럼 참조가 없다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS NEXT(1 + 2) > 0
);

-- 2-인자 형태: PREV(1, 1): 첫 인자가 상수 식이다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(1, 1) > 0
);

-- 컬럼 참조가 없는 복합 내비게이션도 위의
-- 단순 형태와 마찬가지로 거부되어야 한다.
-- PREV(FIRST(1)): 복합형이며 상수뿐이고 컬럼 참조가 없다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(FIRST(1)) > 0
);

-- NEXT(LAST(1 + 2)): 복합형이며 상수 식이고 컬럼 참조가 없다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS NEXT(LAST(1 + 2)) > 0
);

-- PREV(FIRST(1, 2)): 복합형이며 내부가 2-인자이고 컬럼 참조가 없다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(FIRST(1, 2)) > 0
);

-- PREV(FIRST(1), 2): 복합형이며 외부 오프셋뿐이고 컬럼 참조가 없다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(FIRST(1), 2) > 0
);

-- PREV(FIRST(1, 2), 3): 복합형이며 내부·외부 오프셋이 있고 컬럼 참조가 없다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(FIRST(1, 2), 3) > 0
);

-- 비상수 오프셋: 오프셋으로 컬럼 참조를 사용한다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(price, price) > 0
);

-- 비상수 오프셋: 복합형 내부 오프셋에 컬럼 참조를 사용한다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(LAST(price, price), 2) > 0
);

-- 비상수 오프셋: 복합형 외부 오프셋에 컬럼 참조를 사용한다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(LAST(price, 1), price) > 0
);

-- 비상수 오프셋: 오프셋으로 휘발성 함수를 사용한다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(price, random()::int) > 0
);

-- 비상수 오프셋: 복합형 외부 오프셋으로 휘발성 함수를 사용한다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(LAST(price, 1), random()::int) > 0
);

-- 비상수 오프셋: 오프셋으로 서브쿼리를 사용한다
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(price, (SELECT 1)) > 0
);

-- 첫 인자: 서브쿼리 (DEFINE 수준의 서브쿼리 제약에 걸린다)
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS PREV(price + (SELECT 1)) > 0
);

-- nav.arg 안의 휘발성 함수는 플래너에서 거부된다
SELECT company, tdate, price,
       first_value(price) OVER w, last_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(price + random() * 0) >= 0
);

-- nextval은 휘발성이므로 이를 호출하는 DEFINE은 거부된다
CREATE SEQUENCE rpr_seq;
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS price > nextval('rpr_seq')
);
DROP SEQUENCE rpr_seq;

-- 휘발성 DEFINE은 플래너에서 거부되므로, 이를 숨기는 뷰는 생성은 성공하고 읽을
-- 때만 오류가 난다.
CREATE TEMP VIEW rpr_volatile_view AS
SELECT company, tdate, price, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A+)
    DEFINE A AS price > random() * 0
);
SELECT * FROM rpr_volatile_view;
DROP VIEW rpr_volatile_view;

-- DEFINE은 외부 쿼리의 컬럼을 참조할 수 없다.  상관 외부 참조는
-- pull_var_clause 가 그렇지 않으면 발생시킬 내부용 "Upper-level Var" elog가
-- 아니라 깔끔한 오류를 내야 한다.  한정된 외부 참조 (o.threshold):
SELECT * FROM (VALUES (95)) AS o(threshold),
LATERAL (
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS price > o.threshold
    )
) s;
-- 외부 컬럼으로 풀리는 비한정 이름 (threshold):
SELECT * FROM (VALUES (95)) AS o(threshold),
LATERAL (
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS price > threshold
    )
) s;
-- 내비게이션 인자 안의 외부 참조도 거부된다:
SELECT * FROM (VALUES (95)) AS o(threshold),
LATERAL (
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company ORDER BY tdate
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS PREV(o.threshold, 1) > 0
    )
) s;

-- 외부 범위 변수도 로컬 변수와 동일한 두 규칙을 따른다.  전체 행 참조는 전체
-- 행 참조로서 거부되고, 풀리지 않는 이름은 한정자 문제로 보고되지 않고 자기
-- 자신의 진단을 유지한다.
SELECT * FROM (VALUES (95)) AS o(threshold),
LATERAL (
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS (o.*) IS NOT NULL
    )
) s;
SELECT * FROM (VALUES (95)) AS o(threshold),
LATERAL (
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS o.threshhold > 0
    )
) s;

-- 두 부분으로 된 이름이 항상 범위 변수 한정자인 것은 아니다.  SQL 함수의
-- 매개변수와 PL/pgSQL 변수는 둘 다 p_post_columnref_hook 을 통해 풀린다.
-- 그래도 한정자 슬롯은 예약되므로, 이들은 무엇을 가리키는지가 아니라 표기 자체
-- 때문에 거부된다.
CREATE FUNCTION rpr_sqlfn(threshold int) RETURNS SETOF int
LANGUAGE sql AS $$
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS price > rpr_sqlfn.threshold)
$$;

CREATE FUNCTION rpr_plfn(threshold int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM (
        SELECT price FROM rpr_price
        WINDOW w AS (
            PARTITION BY company
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
            INITIAL
            PATTERN (A)
            DEFINE A AS price > rpr_plfn.threshold)
    ) s;
    RETURN n;
END
$$;
SELECT rpr_plfn(0);
DROP FUNCTION rpr_plfn(int);

-- 한정하지 않으면 같은 매개변수를 읽을 수 있다.
CREATE FUNCTION rpr_sqlfn(threshold int) RETURNS SETOF int
LANGUAGE sql AS $$
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS price > threshold)
$$;
SELECT count(*) FROM rpr_sqlfn(0);
DROP FUNCTION rpr_sqlfn(int);

-- 한정자 슬롯은 풀이 전에 한정자만으로 결정되므로, 패턴 변수는 쿼리를 담은
-- 루틴으로부터도 이 슬롯을 가져간다.  함수 이름을 따서 패턴
-- 변수 이름을 지으면 rpr_pv.threshold는 그 패턴 변수의 것이
-- 되고 예약이 보고된다.  함수가 그 이름의 매개변수를 가지고
-- 있는지, 쿼리에 그런 컬럼이 없는지는 여기서 고려되지 않는다.
CREATE FUNCTION rpr_pv(threshold int) RETURNS SETOF int
LANGUAGE sql AS $$
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (rpr_pv)
        DEFINE rpr_pv AS price > rpr_pv.threshold)
$$;

-- 충돌은 정의 중인 DEFINE 변수가 아니라 한정자에서 일어난다.  그 이름의 패턴
-- 변수라면 무엇이든 이 이름을 예약한다.
CREATE FUNCTION rpr_pv(threshold int) RETURNS SETOF int
LANGUAGE sql AS $$
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (rpr_pv A)
        DEFINE A AS price > rpr_pv.threshold)
$$;

-- 복합 매개변수의 필드는 비한정 표기가 없으므로 값을 괄호로 묶어 접근한다.
-- "(p).lo"는 이름을 한정하는 것이 아니라 필드를 선택하는 것이며 한정자 슬롯을
-- 차지하지 않는다.
CREATE TYPE rpr_pair AS (lo int, hi int);
CREATE FUNCTION rpr_compfn(p rpr_pair) RETURNS SETOF int
LANGUAGE sql AS $$
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS price > p.lo)
$$;
CREATE FUNCTION rpr_compfn(p rpr_pair) RETURNS SETOF int
LANGUAGE sql AS $$
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS price > (p).lo)
$$;
SELECT count(*) FROM rpr_compfn(ROW(0, 0)::rpr_pair);
DROP FUNCTION rpr_compfn(rpr_pair);
DROP TYPE rpr_pair;

-- DEFINE 규칙은 참조 훅이 쿼리 파서에 넘기는 이름에 적용된다.  use_variable
-- 풀이 방식에서는 PL/pgSQL 이 먼저 응답하고 자신의 변수가 소유한 이름을 모두
-- 가져가므로, 위에서 거부된 한정 표기는 여기서는 PL/pgSQL 이 풀어버려 규칙에
-- 도달하지 않는다.
CREATE FUNCTION rpr_plfn_var(threshold int) RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    n bigint;
BEGIN
    SELECT count(*) INTO n FROM (
        SELECT price FROM rpr_price
        WINDOW w AS (
            PARTITION BY company
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
            INITIAL
            PATTERN (A)
            DEFINE A AS price > rpr_plfn_var.threshold)
    ) s;
    RETURN n;
END
$$;
SELECT rpr_plfn_var(0);
DROP FUNCTION rpr_plfn_var(int);

-- 패턴 변수 이름도 마찬가지다.  기본 풀이 방식에서는 PL/pgSQL 이 그 이름을
-- 거절하므로 예약에 도달하고, 충돌이 풀리는 대신 보고된다.
CREATE FUNCTION rpr_conflictfn_err() RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    a rpr_price%ROWTYPE;
    n bigint;
BEGIN
    a.price := 95;
    SELECT count(*) INTO n FROM (
        SELECT price FROM rpr_price
        WINDOW w AS (
            PARTITION BY company
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
            INITIAL
            PATTERN (A)
            DEFINE A AS price > a.price)
    ) s;
    RETURN n;
END
$$;
SELECT rpr_conflictfn_err();
DROP FUNCTION rpr_conflictfn_err();

CREATE FUNCTION rpr_conflictfn() RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    a rpr_price%ROWTYPE;
    n bigint;
BEGIN
    a.price := 95;
    SELECT count(*) INTO n FROM (
        SELECT price FROM rpr_price
        WINDOW w AS (
            PARTITION BY company
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
            INITIAL
            PATTERN (A)
            DEFINE A AS price > a.price)
    ) s;
    RETURN n;
END
$$;
SELECT rpr_conflictfn();
DROP FUNCTION rpr_conflictfn();

-- 참조 훅이 소유한 이름에 붙은 별표는 FROM 절 릴레이션에 대한 참조가 아니므로,
-- DEFINE 조건에서도 다른 곳과 똑같이 전개된다. 이 전개를 하지 않는다고 해서
-- 그런 이름이 거부되는 것은 아니다.  그 경우 "rec.*"는 단일 전체 값 "rec"로
-- 읽히는데, 이는 다른 조건이며 행 생성자가 항목 수를 세지 않는
-- 곳에서는 조용히 달라진다.  아래 각 함수는 레코드가 (1,2)일
-- 때 모든 행에 일치하고 그렇지 않을 때는 하나도 일치하지
-- 않아야 하므로, 잘못 읽으면 오류 대신 잘못된 개수를 돌려준다.
CREATE TYPE rpr_pair AS (a int, b int);
CREATE TEMP TABLE rpr_rec (id int);
INSERT INTO rpr_rec VALUES (1), (2), (3);

-- 기본 풀이 방식에서는 post 훅이 이 이름에 응답한다:
CREATE FUNCTION rpr_recstar(x int, y int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    rec rpr_pair;
    n bigint;
BEGIN
    rec := ROW(x, y);
    SELECT count(*) OVER w INTO n FROM rpr_rec
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS ROW(rec.*)::text = '(1,2)')
    LIMIT 1;
    RETURN n;
END
$$;
SELECT rpr_recstar(1, 2);
SELECT rpr_recstar(1, 3);
DROP FUNCTION rpr_recstar(int, int);

-- use_variable 에서는 대신 pre 훅이 응답한다:
CREATE FUNCTION rpr_recstar_var(x int, y int) RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    rec rpr_pair;
    n bigint;
BEGIN
    rec := ROW(x, y);
    SELECT count(*) OVER w INTO n FROM rpr_rec
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS ROW(rec.*)::text = '(1,2)')
    LIMIT 1;
    RETURN n;
END
$$;
SELECT rpr_recstar_var(1, 2);
SELECT rpr_recstar_var(1, 3);
DROP FUNCTION rpr_recstar_var(int, int);

-- DEFINE 조건 밖에서의 같은 표기이며, 위 두 경우가 이것과 일치해야 한다:
CREATE FUNCTION rpr_recstar_plain(x int, y int) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    rec rpr_pair;
BEGIN
    rec := ROW(x, y);
    RETURN (SELECT ROW(rec.*)::text FROM rpr_rec LIMIT 1);
END
$$;
SELECT rpr_recstar_plain(1, 2);
DROP FUNCTION rpr_recstar_plain(int, int);

-- FROM 절 릴레이션은 그런 함수 안팎 어디서도 그런 이름이 아니다.
CREATE FUNCTION rpr_relstar() RETURNS bigint
LANGUAGE plpgsql AS $$
#variable_conflict use_variable
DECLARE
    rec rpr_pair := ROW(1, 2);
    n bigint;
BEGIN
    SELECT count(*) OVER w INTO n FROM rpr_rec
    WINDOW w AS (
        ORDER BY id
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        PATTERN (A+)
        DEFINE A AS ROW(rpr_rec.*)::text IS NOT NULL)
    LIMIT 1;
    RETURN n;
END
$$;
SELECT rpr_relstar();
DROP FUNCTION rpr_relstar();
DROP TABLE rpr_rec;
DROP TYPE rpr_pair;

-- 함수 호출의 한정자로 쓰인 외부 범위 변수는 Var가 아니라 FuncExpr 로서
-- DEFINE에 도달하므로, 외부 참조를 식별하는 것은 결과 노드의 모양이 아니라
-- 한정자가 풀린 수준이다.
CREATE TABLE rpr_outer (threshold int);
INSERT INTO rpr_outer VALUES (95);
CREATE FUNCTION rpr_rowfn(rpr_outer) RETURNS int LANGUAGE sql AS 'SELECT 1';
SELECT * FROM rpr_outer AS o,
LATERAL (
    SELECT price FROM rpr_price
    WINDOW w AS (
        PARTITION BY company
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        INITIAL
        PATTERN (A)
        DEFINE A AS o.rpr_rowfn > 0
    )
) s;
DROP FUNCTION rpr_rowfn(rpr_outer);
DROP TABLE rpr_outer;

-- DEFINE은 스키마로 한정된 컬럼 참조(이름 부분이 3개 이상)가 풀리고 나면 이를
-- 거부한다.  한정된 형태 자체가 허용되지 않는다.  (rpr_price 는 임시
-- 테이블이므로 여기서는 pg_temp 로 한정한다.) 3-부분 (schema.table.column):
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS pg_temp.rpr_price.price > 0
);
-- 전체 행 변형 (schema.table.*):
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS (pg_temp.rpr_price.*) IS NOT NULL
);
-- 두 부분으로 테이블 한정된 전체 행 참조도 거부되며, 한정자 규칙이 아니라
-- 전체 행 검사에 의해서다.  오류는 한정자가 아니라 전체 행 참조를 지목한다.
-- 2-부분 (table.*):
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS (rpr_price.*) IS NOT NULL
);
-- 형태가 한정자를 조회하기 전에 결정되므로, 철자가 틀린 테이블 이름은 누락된
-- FROM 절 항목이 아니라 작성된 그대로의 전체 행 참조로 보고된다:
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS (stok.*) IS NOT NULL
);
-- 행 생성자를 통해서도 마찬가지다:
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS ROW(stok.*) IS NOT NULL
);

-- 행 생성자는 transformExpressionList()를 통해 같은 참조에
-- 도달하는데, 이 함수의 별표 전개는 이들을 RTE 단위로 개별 컬럼
-- Var로 묶어 모든 검사를 지나친다.  DEFINE은 이를 건너뛴다.
-- ROW(schema.table.*):
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS ROW(pg_temp.rpr_price.*) IS NOT NULL
);
-- ROW(table.*):
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS ROW(rpr_price.*) IS NOT NULL
);
-- ROW 키워드는 생략할 수 있으므로, 맨 생성자도 같은 처리가 필요하다:
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS (rpr_price.*, 1) IS NOT NULL
);
-- 불필요한 괄호로도 우회할 수 없다:
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS ROW((rpr_price.*)) IS NOT NULL
);
-- 패턴 변수 한정자는 별도의 거부 부류다:
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS ROW(A.*) IS NOT NULL
);
-- 표준이 DEFINE 예제를 작성할 때 쓰는 형태는 이 단순한 두 부분 형태이며, 풀이
-- 전에 한정자만으로 결정된다.
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS A.price > 100
);
-- 한정자만으로 결정한다는 것은, 그렇지 않았다면 범위 변수가 응답했을 이름을
-- 패턴 변수가 가져간다는 뜻이다.  여기서 "a"가 실제 별칭임에도 거부는 별칭이
-- 아니라 패턴 변수를 지목한다.
SELECT price FROM rpr_price AS a
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS a.price > 100
);
-- 패턴 변수 및 전체 행 거부와 달리, 범위 변수 및 스키마 한정 거부는 참조가
-- 풀린 뒤에만 이를 분류한다.  그래서 철자가 틀린 컬럼은 다른 곳에서와 같은
-- 진단과 제안을 그대로 유지한다.  한정자만으로 판단했다면 이름의 나머지 부분을
-- 보기도 전에 범위 변수 문제로 보고했을 것이다.
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS rpr_price.pric > 0
);
SELECT price FROM rpr_price
WINDOW w AS (
    PARTITION BY company
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS pg_temp.rpr_price.pric > 0
);
-- 비교를 위한, DEFINE 절 밖에서의 같은 오타:
SELECT price FROM rpr_price WHERE rpr_price.pric > 0;

-- 풀리지 않은 컬럼을 전체 행에 대한 함수 호출로 재시도하면 쿼리에 없는 전체 행
-- 참조가 만들어진다.  이를 전체 행 참조로 보고해서도 안 되고, 그대로
-- 통과시켜서도 안 된다.  아래의 rpr_tag(rpr_stock)는 풀리므로 재시도는
-- 성공하고, 그 결과는 전체 행 검사가 아니라 한정자 규칙에 의해 거부된다.
CREATE FUNCTION rpr_tag(rpr_stock) RETURNS int
    LANGUAGE sql IMMUTABLE AS $$SELECT 1$$;
SELECT price FROM rpr_stock
WINDOW w AS (
    PARTITION BY part_id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS rpr_stock.rpr_tag > 0
);
SELECT price FROM rpr_stock
WINDOW w AS (
    PARTITION BY part_id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A)
    DEFINE A AS public.rpr_stock.rpr_tag > 0
);
DROP FUNCTION rpr_tag(rpr_stock);

-- JOIN USING 별칭은 자신의 전체 행 Var를 가지지 않으므로, 같은 재시도는 대신
-- 이를 행 생성자로 전개한다. 이 재시도는 별표를 가지지 않으므로 DEFINE은 이를
-- 그 갈래까지 통과시킨다.
CREATE TEMP TABLE rpr_j_l (x int, y int);
CREATE TEMP TABLE rpr_j_r (x int, z int);
SELECT count(*) OVER w FROM (rpr_j_l JOIN rpr_j_r USING (x)) j
WINDOW w AS (
    ORDER BY x
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS j.yy > 0
);
SELECT count(*) OVER w FROM (rpr_j_l JOIN rpr_j_r USING (x)) j
WINDOW w AS (
    ORDER BY x
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS j.y > 0
);
SELECT count(*) OVER w FROM (rpr_j_l JOIN rpr_j_r USING (x)) j
WINDOW w AS (
    ORDER BY x
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS (j.*) IS NOT NULL
);
DROP TABLE rpr_j_l, rpr_j_r;

-- 일반 컬럼에 대한 행 생성자는 영향받지 않는다.
SELECT company, tdate, count(*) OVER w AS cnt
FROM rpr_price
WHERE company = 'company2' AND tdate <= '2023-07-03'
WINDOW w AS (
    PARTITION BY company
    ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    INITIAL
    PATTERN (A+)
    DEFINE A AS ROW(price, price) IS NOT NULL
);

-- DEFINE 조건에 대한 제약은 그 안에 중첩되어 고유한 식 종류를 갖는 절까지
-- 포함해 조건 전체를 대상으로 한다.  조건이 닿을 수 있는 그런 절은 FILTER와
-- 집계의 ORDER BY 두 가지이며, 아래 각 사례 앞에는 같은 참조를 조건 안에 직접
-- 적은 경우가 나오는데, 중첩된 경우도 이 거부를 그대로 유지해야 한다.
CREATE TEMP TABLE rpr_nest_i (i int, v int);
CREATE TEMP TABLE rpr_nest_o (v int);
-- 외부 쿼리 컬럼:
SELECT o.v, (SELECT count(*) OVER w FROM rpr_nest_i inn
             WINDOW w AS (
                 ORDER BY inn.i
                 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                 PATTERN (A+)
                 DEFINE A AS o.v > 0)
             LIMIT 1)
FROM rpr_nest_o o GROUP BY o.v;
SELECT o.v, (SELECT count(*) OVER w FROM rpr_nest_i inn
             WINDOW w AS (
                 ORDER BY inn.i
                 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                 PATTERN (A+)
                 DEFINE A AS count(*) FILTER (WHERE o.v > 0) > 0)
             LIMIT 1)
FROM rpr_nest_o o GROUP BY o.v;
SELECT o.v, (SELECT count(*) OVER w FROM rpr_nest_i inn
             WINDOW w AS (
                 ORDER BY inn.i
                 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                 PATTERN (A+)
                 DEFINE A AS v > count(1 ORDER BY o.v))
             LIMIT 1)
FROM rpr_nest_o o GROUP BY o.v;
-- 패턴 변수 한정자이며, 외부 별칭이 같은 이름에 응답하므로 이를 통과시키면
-- 대신 외부 컬럼을 조용히 읽게 된다:
SELECT count(*) OVER w FROM rpr_nest_i A
WINDOW w AS (
    ORDER BY A.i
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS A.v > 0
);
SELECT A.v, (SELECT count(*) OVER w FROM rpr_nest_i inn
             WINDOW w AS (
                 ORDER BY inn.i
                 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
                 PATTERN (A+)
                 DEFINE A AS percentile_disc(0.5)
                             WITHIN GROUP (ORDER BY A.v) > 0)
             LIMIT 1)
FROM rpr_nest_i A GROUP BY A.v;
-- 전체 행 참조이며, 행 생성자라면 RTE별로 전개했을 것이다:
SELECT (SELECT count(*) OVER w FROM rpr_nest_i inn
        WINDOW w AS (
            ORDER BY inn.i
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
            PATTERN (A+)
            DEFINE A AS ROW(o.*)::text IS NOT NULL)
        LIMIT 1)
FROM rpr_nest_o o;
SELECT (SELECT count(*) OVER w FROM rpr_nest_i inn
        WINDOW w AS (
            ORDER BY inn.i
            ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
            PATTERN (A+)
            DEFINE A AS percentile_disc(0.5)
                        WITHIN GROUP (ORDER BY ROW(o.*)::text) IS NOT NULL)
        LIMIT 1)
FROM rpr_nest_o o GROUP BY o.v;
-- 서브쿼리:
SELECT count(*) OVER w FROM rpr_nest_i inn
WINDOW w AS (
    ORDER BY inn.i
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS v > (SELECT 1)
);
SELECT count(*) OVER w FROM rpr_nest_i inn
WINDOW w AS (
    ORDER BY inn.i
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS count(*) FILTER (WHERE (SELECT 1) = 1) > 0
);
-- 중첩 자체가 거부되는 것은 아니다.  그 안에 금지된 것이 없다면, 조건이 걸려
-- 넘어지는 대상은 FILTER를 가진 집계다.
SELECT count(*) OVER w FROM rpr_nest_i inn
WINDOW w AS (
    ORDER BY inn.i
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS count(*) FILTER (WHERE v > 0) > 0
);
DROP TABLE rpr_nest_i, rpr_nest_o;

--
-- 2-인자 PREV/NEXT: 기능 테스트
--

-- PREV(price, 2): A=any일 때, B는 price가 2행 앞의 값보다 클 때 일치한다.
-- company1(100, 200, 150, 140, 150, 90, 110, 130, 120, 130)에서는
-- 200 -> 150 이고, 이어서 110 -> 130 -> 120 이며,
-- 130 이 130 과 같기만 한 지점에서 멈춘다.
SELECT company, tdate, price,
       first_value(price) OVER w, last_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE
        A AS TRUE,
        B AS price > PREV(price, 2)
);

-- NEXT(price, 2): A는 price가 2행 뒤의 값보다 큰 동안
-- 일치하므로, company1에서는 200 이 단독으로 일치한다.  150 은
-- 그 앞의 150 과 같기만 하기 때문이며, 이어서 140, 150 이
-- 일치하다가 90 이 130 에 못 미치는 지점에서 끝난다.
SELECT company, tdate, price,
       first_value(price) OVER w, last_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS price > NEXT(price, 2)
);

-- PREV/NEXT 인자 안의 식: 식은 대상 행에서 평가된다 PREV(price - 50, 1): 1 행
-- 앞에서 (price - 50)을 가져온다
SELECT company, tdate, price,
       first_value(price) OVER w, last_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS price > PREV(price - 50, 1)
);

-- NEXT(price * 2, 1): 1 행 뒤에서 (price * 2)를 가져온다
SELECT company, tdate, price,
       first_value(price) OVER w, last_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS price < NEXT(price * 2, 1)
);

-- 큰 오프셋: 1000 행 시리즈에서 PREV(val, 999)는 마지막 행에서만 일치한다.
-- NEXT(val, 999)는 첫 행에서만 일치한다
SELECT val, first_value(val) OVER w, last_value(val) OVER w, count(*) OVER w
FROM generate_series(1, 1000) AS t(val)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(val, 999) = 1
)
ORDER BY val DESC LIMIT 3;

SELECT val, first_value(val) OVER w, last_value(val) OVER w, count(*) OVER w
FROM generate_series(1, 1000) AS t(val)
WINDOW w AS (
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS NEXT(val, 999) = 1000
)
LIMIT 3;

-- PREV(price, 0): 오프셋 0 은 현재 행을 뜻하며 항상 price와 같다 A+는 파티션
-- 전체를 하나의 그룹으로 일치시킨다; count = 파티션 크기
SELECT company, tdate, price,
       first_value(price) OVER w, last_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(price, 0) = price
);

-- 2-인자 PREV/NEXT: 음수 오프셋
SELECT company, tdate, price, first_value(price) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(price, -1) IS NOT NULL
);

-- 2-인자 PREV/NEXT: NULL 오프셋 (타입 있음)
SELECT company, tdate, price, first_value(price) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(price, NULL::int8) IS NOT NULL
);

-- 2-인자 PREV/NEXT: NULL 오프셋 (타입 없음)
SELECT company, tdate, price, first_value(price) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(price, NULL) IS NOT NULL
);

-- 2-인자 PREV/NEXT: 호스트 변수가 음수이거나 NULL
PREPARE test_prev_offset(int8) AS
SELECT company, tdate, price, first_value(price) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS price > PREV(price, $1)
);
EXECUTE test_prev_offset(-1);
EXECUTE test_prev_offset(NULL);
DEALLOCATE test_prev_offset;

-- 2-인자 PREV/NEXT: 식을 가진 호스트 변수 (0 + $1)
PREPARE test_prev_offset(int8) AS
SELECT company, tdate, price, first_value(price) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS price > PREV(price, 0 + $1)
);
EXECUTE test_prev_offset(-1);
EXECUTE test_prev_offset(NULL);
DEALLOCATE test_prev_offset;

-- 2-인자 PREV/NEXT: 양수 값을 가진 호스트 변수.  제네릭 플랜은 매개변수를
-- Param으로 유지하므로 오프셋은 실행 시점에 풀린다; 커스텀 플랜이라면 이를
-- 상수로 접어 도달 범위를 초기화 시점에 정한다.
SET plan_cache_mode = force_generic_plan;
PREPARE test_prev_offset(int8) AS
SELECT company, tdate, price, first_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS price > PREV(price, $1)
);
EXECUTE test_prev_offset(1);
EXECUTE test_prev_offset(2);
DEALLOCATE test_prev_offset;
RESET plan_cache_mode;

-- 2-인자: 같은 DEFINE 절에서 오프셋이 다른 두 PREV
-- B: price가 1 행 앞 값과 2행 앞 값을 모두 초과한다
SELECT company, tdate, price,
       first_value(price) OVER w, last_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE
        A AS TRUE,
        B AS price > PREV(price, 1) AND price > PREV(price, 2)
);

-- 2-인자: 같은 DEFINE 절에서 명시적 오프셋을 가진 PREV와 NEXT A: price가 1 행
-- 앞보다 크고 1 행 뒤보다 작다 (상승 중인 내부 지점)
SELECT company, tdate, price,
       first_value(price) OVER w, last_value(price) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+)
    DEFINE A AS price > PREV(price, 1) AND price < NEXT(price, 1)
);

-- 참조 전달 타입: 서로 다른 위치를 대상으로 하는 두 PREV 호출이므로, 첫 번째
-- 내비게이션 결과가 두 번째 가져오기 후에도 살아남아야 한다.  B는 1 행 앞과 2
-- 행 앞의 tdate 텍스트를 비교한다.
SELECT company, tdate, tdate::text AS tdate_text,
       first_value(tdate::text) OVER w, last_value(tdate::text) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE
        A AS TRUE,
        B AS PREV(tdate::text, 1) > PREV(tdate::text, 2)
);

-- numeric: PREV(price::numeric, 1) > PREV(price::numeric, 2)
-- B는 1 행 앞 price가 2 행 앞 price보다 클 때 일치한다 (상승 쌍).
SELECT company, tdate, price::numeric AS nprice,
       first_value(price::numeric) OVER w, last_value(price::numeric) OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
    PARTITION BY company ORDER BY tdate
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE
        A AS TRUE,
        B AS PREV(price::numeric, 1) > PREV(price::numeric, 2)
);

-- 캐스트가 아니라 맨 참조 전달 컬럼: 두 내비게이션이 서로 다른 행에
-- 떨어지므로, 두 번째 가져오기는 첫 번째 결과가 가리키는 튜플을
-- 해제한다.  위의 캐스트들은 새 데이텀을 할당하므로 이 상황에 도달하지
-- 않는다; 오직 EEOP_RPR_NAV_RESTORE 의 datumCopy 만이 이 값을 살려 둔다.
CREATE TEMP TABLE rpr_byref (id int, s text);
INSERT INTO rpr_byref VALUES
  (1, 'aaa'), (2, 'bbb'), (3, 'ccc'), (4, 'bbb'), (5, 'ddd'), (6, 'aaa');
SELECT id, s, first_value(s) OVER w AS fs, last_value(s) OVER w AS ls,
       count(*) OVER w AS cnt
FROM rpr_byref
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(s, 1) > PREV(s, 2)
);
DROP TABLE rpr_byref;

-- 내비게이션 결과에 대한 typmod 강제 변환: DEFINE 안에서
-- PREV(p) (numeric(10,3) 컬럼)를 더 좁은 numeric(8,2)로
-- 캐스팅하면 coerce_type_typmod 가 강제 실행되며,
-- 이는 RPRNavExpr 에 대해 exprTypmod()를 호출한다.
CREATE TEMP TABLE rpr_typmod (id int, p numeric(10,3));
INSERT INTO rpr_typmod VALUES (1, 1.5), (2, 2.5), (3, 3.5);
SELECT id, count(*) OVER w AS cnt
FROM rpr_typmod
WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS CAST(PREV(p) AS numeric(8,2)) > 0
);
DROP TABLE rpr_typmod;

--
-- FIRST/LAST 내비게이션
--

-- FIRST/LAST용 테스트 데이터: 값이 순환하여 특정 위치에서 FIRST(val) =
-- LAST(val)이 된다.
CREATE TEMP TABLE rpr_nav_cycle (id int, val int);
INSERT INTO rpr_nav_cycle VALUES (1,10),(2,20),(3,30),(4,10),(5,50),(6,10);

-- FIRST(val) = 상수: match_start 의 val이 10 일 때 B가 일치한다
-- match_start=1(10): A=id1, B=id2, FIRST(val)=10 -> 매치 {1,2}
-- match_start=3(30): A=id3, B=id4, FIRST(val)=30!=10 -> 매치 없음
-- match_start=4(10): A=id4, B=id5, FIRST(val)=10 -> 매치 {4,5}
SELECT id, val, first_value(id) OVER w AS mf, last_value(id) OVER w AS ml
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B)
    DEFINE A AS TRUE, B AS FIRST(val) = 10
);

-- LAST(val): 항상 현재 행의 val과 같다 (기본 오프셋 0) 다음과 동등하다: B AS
-- val > 15
SELECT id, val, first_value(id) OVER w AS mf, last_value(id) OVER w AS ml
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B)
    DEFINE A AS TRUE, B AS LAST(val) > 15
);

-- FIRST(val) = LAST(val)인 소극적 A+?: 첫 행과
-- 마지막 행의 val이 같은 최단 매치를 찾는다.
-- match_start=1(10): 소극적 매칭이 일찍 B를 시도한다:
--   id2(20!=10), id3(30!=10), id4(10=10) -> 매치 {1,2,3,4}
-- match_start=5(50): id6(10!=50) -> 매치 없음
SELECT id, val, first_value(id) OVER w AS mf, last_value(id) OVER w AS ml
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+? B)
    DEFINE A AS TRUE, B AS FIRST(val) = LAST(val)
);

-- FIRST(val) = LAST(val)인 탐욕적 A+: 첫 행과
-- 마지막 행의 val이 같은 최장 매치를 찾는다.
-- match_start=1(10): 탐욕적 A가 모두 먹어치우고, B가 마지막을 시도한다:
--   id6(10=10) -> 매치 {1,2,3,4,5,6}
SELECT id, val, first_value(id) OVER w AS mf, last_value(id) OVER w AS ml
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+ B)
    DEFINE A AS TRUE, B AS FIRST(val) = LAST(val)
);

-- FIRST(val) = LAST(val)에서의 SKIP TO NEXT ROW: 중첩되는 매치 시도.  각 행은
-- 자신에서 시작하는 매치만 보고한다.
SELECT id, val, first_value(id) OVER w AS mf, last_value(id) OVER w AS ml
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A+? B)
    DEFINE A AS TRUE, B AS FIRST(val) = LAST(val)
);

-- FIRST/LAST 2-인자 오프셋 형태
--
-- FIRST(val, 0) = FIRST(val): match_start 행
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS FIRST(val, 0) = 10
);

-- FIRST(val, 1): match_start + 1 행 (매치의 두 번째 행)
-- match_start=1(10): FIRST(val,1)=20, B는 val=20 을
-- 필요로 한다 -> id2(20) 매치, id3(30)은 아님
-- match_start=3(30): FIRST(val,1)=10, B는
-- val=10 을 필요로 한다 -> id4(10) 매치
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS val = FIRST(val, 1)
);

-- FIRST(val, 99): 매치 범위를 벗어난 오프셋 -> NULL, 매치 없음
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS FIRST(val, 99) IS NOT NULL
);

-- LAST(val, 0) = LAST(val): 현재 행
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS LAST(val, 0) > 15
);

-- LAST(val, 1): 현재에서 1행 앞 (이전 매치 행)
-- id2에서 B를 평가할 때: LAST(val,1) = id1의 val = 10
-- B는 이전 행의 val < 30 일 때 일치한다
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS LAST(val, 1) < 30
);

-- LAST(val, 99): match_start 이전의 오프셋 -> NULL
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS LAST(val, 99) IS NOT NULL
);

-- 오류: NULL 오프셋
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS FIRST(val, NULL::int8) IS NULL
);

-- 오류: 음수 오프셋
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS LAST(val, -1) IS NULL
);

-- 함수 표기법: RPR 내비게이션이 아니라 컬럼에 접근해야 한다
CREATE TEMP TABLE rpr_names (prev int, next int, first text, last text);
INSERT INTO rpr_names VALUES (1, 2, 'Joe', 'Blow');
SELECT prev(f), next(f), first(f), last(f) FROM rpr_names f;
DROP TABLE rpr_names;

-- 복합 내비게이션: PREV(FIRST(val), M)
-- rpr_nav_cycle: (1,10),(2,20),(3,30),(4,10),(5,50),(6,10)
-- PREV(FIRST(val), 1): 대상 = match_start + 0 - 1 = match_start - 1
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(FIRST(val), 1) > 0
);

-- NEXT(FIRST(val, 1), 1): 대상 = match_start + 1 + 1 = match_start + 2
-- match_start=1, id2에서의 B: 대상=1+1+1=3(val=30), 30>0 -> 참
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(FIRST(val, 1), 1) > 0
);

-- PREV(LAST(val), 2): LAST(val)은 현재 행이므로
-- (내부 오프셋 0), 대상 = currentpos - 0 - 2 = currentpos - 2 가
-- 된다.  PREV(val, 2)와 같은 역방향 도달 범위다.
-- currentpos=2 일 때 (시작 id=1): 대상=0 -> 범위 밖 -> NULL -> B 실패.
-- currentpos=3 일 때 (시작 id=2): 대상=1(val=10) -> 범위 안 -> B가
-- id3..id6에서 실행되어 매치는 id2..id6이 된다.
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(LAST(val), 2) IS NOT NULL
);

-- NEXT(LAST(val, 1), 2): LAST(val, 1)은 1행 앞이므로 (내부 오프셋 1),
-- NEXT가 2 를 더해 대상 = currentpos - 1 + 2 = currentpos + 1 이
-- 된다.  1행 뒤를 본다는 점에서 NEXT(val, 1)과 같다.
-- currentpos=2 일 때 (시작 id=1): 대상=3(val=30) -> 범위 안 -> B 참.
-- B는 id5까지 참을 유지하고 (대상=6), id6에서는
-- 대상=7 -> 범위 밖 -> NULL이 되어 매치는 id1..id5가 된다.
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(LAST(val, 1), 2) IS NOT NULL
);

-- 복합형: 외부 오프셋이 파티션을 벗어남 (PREV가 멀리 앞으로)
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(FIRST(val), 99) IS NOT NULL
);

-- 복합형: 외부 오프셋이 파티션을 벗어남 (NEXT가 멀리 뒤로)
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(FIRST(val), 99) IS NOT NULL
);

-- 복합형: 내부 오프셋이 매치 범위를 벗어남 (FIRST 오프셋이 너무 큼)
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(FIRST(val, 99), 1) IS NOT NULL
);

-- 복합형: 내부 오프셋이 매치 범위를 벗어남 (LAST 오프셋이 너무 큼)
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(LAST(val, 99), 1) IS NOT NULL
);

-- 복합형: NULL 외부 오프셋 (런타임 오류)
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(FIRST(val), NULL::int8) IS NULL
);

-- 복합형: 음수 외부 오프셋 (런타임 오류)
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS NEXT(LAST(val), -1) IS NULL
);

-- 복합형: 범위를 벗어난 내부 오프셋이 있어도 외부 오프셋의 검증을 건너뛰어서는
-- 안 된다.  네 갈래 모두 같은 호출을 통해 외부 오프셋을 풀므로 각각 한 번씩
-- 나타나며, 음수와 NULL 경우는 각각 두 갈래를 차지한다.
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(FIRST(val, 99), -1) IS NULL
);
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(LAST(val, 99), NULL::int8) IS NULL
);
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(FIRST(val, 99), NULL::int8) IS NULL
);
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(LAST(val, 99), -1) IS NULL
);

-- 호스트 변수로도 같은 내용이며, 이때 오프셋은 플래너가 접을 수 있는 Const가
-- 아니다: prepared statement 하나이며 외부 오프셋만이 결과를 결정한다.  여기서
-- 도달 범위는 "runtime"으로 읽힌다; 커스텀 플랜이라면 이를 99 - 1 = 98 로
-- 접었을 것이다.
SET plan_cache_mode = force_generic_plan;
PREPARE test_compound_illegal(int8, int8) AS
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(FIRST(val, $1), $2) IS NULL
);
EXPLAIN (COSTS OFF) EXECUTE test_compound_illegal(99, 1);
EXECUTE test_compound_illegal(99, 1);
EXECUTE test_compound_illegal(99, -1);
EXECUTE test_compound_illegal(99, NULL);
EXECUTE test_compound_illegal(0, -1);
DEALLOCATE test_compound_illegal;
RESET plan_cache_mode;

-- 오프셋은 첫 행을 가져오기 전에 확정되므로, 행이 전혀
-- 없는 파티션이라도 잘못된 오프셋은 똑같이 거부하고,
-- 올바른 오프셋은 실패하는 대신 행을 반환하지 않는다.
CREATE TABLE rpr_nav_empty (id int, val int);
SELECT id, count(*) OVER w FROM rpr_nav_empty WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(val, -1) IS NULL
);
SELECT id, count(*) OVER w FROM rpr_nav_empty WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(val, 1) IS NULL
);
SET plan_cache_mode = force_generic_plan;
PREPARE test_empty_offset(int8) AS
SELECT id, count(*) OVER w FROM rpr_nav_empty WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(val, $1) IS NULL
);
EXECUTE test_empty_offset(-1);
EXECUTE test_empty_offset(NULL);
EXECUTE test_empty_offset(1);
DEALLOCATE test_empty_offset;
RESET plan_cache_mode;
DROP TABLE rpr_nav_empty;

-- 외부 오프셋이 int64를 오버플로한다: 대상 위치가 범위 밖 -> NULL.  단순
-- NEXT(val, INT64_MAX): currentpos + INT64_MAX 가 오버플로한다.
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS NEXT(val, 9223372036854775807) IS NULL
);

-- 복합형 NEXT(FIRST()): 외부 오프셋 오버플로.
-- 내부 오프셋 1 은 inner_pos >= 1 을 강제하므로, 모든
-- 매치에서 inner_pos + INT64_MAX 가 오버플로한다.
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(FIRST(val, 1), 9223372036854775807) IS NULL
);

-- 복합형 NEXT(LAST()): 외부 오프셋 오버플로.
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS NEXT(LAST(val), 9223372036854775807) IS NULL
);

-- 내부 오프셋이 int64를 오버플로한다.  위의 사례들은 모두 외부 오프셋을
-- 적용하는 동안 오버플로하지만, 이 둘은 외부 오프셋이 적용되기 전, 내부 위치를
-- 계산하는 동안 오버플로한다.  A는 첫 행에서 거짓이므로 거기서는 매치가
-- 시작하지 않고, B가 평가되는 곳이라면 어디든 match_start 는 최소 1 이다;
-- 따라서 match_start + INT64_MAX 가 오버플로한다.  match_start 가 0 이면 합은
-- 여전히 범위에 들어오고, 그 아래의 clamp가 대신 답한다.
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS val > 10, B AS FIRST(val, 9223372036854775807) IS NULL
);

-- 복합 내비게이션을 통해 도달하는 같은 오버플로이며, 외부 오프셋이 적용되기
-- 전에 일어난다
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS val > 10, B AS NEXT(FIRST(val, 9223372036854775807), 1) IS NULL
);

-- 복합형: 양쪽 모두 기본 오프셋
-- PREV(FIRST(val)): inner=0 (match_start), outer=1 -> 대상 = match_start - 1
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(FIRST(val)) IS NOT NULL
);

-- NEXT(LAST(val)): inner=0 (currentpos), outer=1 -> 대상 = currentpos + 1
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(LAST(val)) IS NOT NULL
);

-- 복합형: 내부 NULL 오프셋 (런타임 오류)
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS PREV(FIRST(val, NULL::int8), 1) IS NULL
);

-- 복합형: 내부 음수 오프셋 (런타임 오류)
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A+)
    DEFINE A AS NEXT(LAST(val, -1), 1) IS NULL
);

-- bigint로의 암묵적 캐스트가 없는 타입의 오프셋 인자 (구문분석 오류)
SELECT id, val, count(*) OVER w FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS val > PREV(val, 1.5)
);

-- 복합형 + 호스트 변수 오프셋
PREPARE test_compound_offset(int8, int8) AS
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(FIRST(val, $1), $2) IS NOT NULL
);
EXECUTE test_compound_offset(0, 1);
EXECUTE test_compound_offset(1, 1);
DEALLOCATE test_compound_offset;

-- 복합형 + SKIP TO NEXT ROW: PREV(FIRST())를 사용한 중첩 매치
SELECT id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP TO NEXT ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS PREV(FIRST(val), 1) > 0
);

-- 복합형 + 여러 파티션
CREATE TEMP TABLE rpr_nav_part (gid int, id int, val int);
INSERT INTO rpr_nav_part VALUES
    (1,1,10),(1,2,20),(1,3,30),
    (2,1,40),(2,2,50),(2,3,60);
SELECT gid, id, val, first_value(id) OVER w AS mf, count(*) OVER w AS cnt
FROM rpr_nav_part WINDOW w AS (
    PARTITION BY gid ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A B+)
    DEFINE A AS TRUE, B AS NEXT(FIRST(val), 1) > 0
);
DROP TABLE rpr_nav_part;

-- 역방향 중첩: FIRST가 PREV를 감싸는 것은 금지된다
SELECT id, val FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B)
    DEFINE A AS TRUE, B AS FIRST(PREV(val)) > 0
);

-- 역방향 중첩: LAST가 NEXT를 감싸는 것은 금지된다
SELECT id, val FROM rpr_nav_cycle WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (A B)
    DEFINE A AS TRUE, B AS LAST(NEXT(val)) > 0
);

DROP TABLE rpr_nav_cycle;

--
-- SKIP TO / 역추적 / 프레임 경계
--

-- 모든 것을 매치한다
SELECT company, tdate, price, first_value(price) OVER w, last_value(price) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 INITIAL
 PATTERN (A+)
 DEFINE
  A AS TRUE
);

-- 축소된 프레임을 벗어난 nth_value (IGNORE NULLS 없음)
SELECT company, tdate, price,
 nth_value(price, 5) OVER w AS nth_5
FROM rpr_price
WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (START UP+ DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- 행 재분류가 있는 역추적
-- AFTER MATCH SKIP PAST LAST ROW를 사용
SELECT company, tdate, price, first_value(tdate) OVER w, last_value(tdate) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 INITIAL
 PATTERN (A+ B+)
 DEFINE
  A AS price > 100,
  B AS price > 100
);

-- 행 재분류가 있는 역추적
-- AFTER MATCH SKIP TO NEXT ROW를 사용
SELECT company, tdate, price, first_value(tdate) OVER w, last_value(tdate) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP TO NEXT ROW
 INITIAL
 PATTERN (A+ B+)
 DEFINE
  A AS price > 100,
  B AS price > 100
);

-- 제한된 프레임에서의 SKIP TO NEXT ROW
-- 각 행은 자신의 프레임 안에서 자기만의 매치를 만들어야 한다
WITH data AS (
 SELECT * FROM (VALUES
  ('A', 1), ('A', 2),
  ('B', 3), ('B', 4)
 ) AS t(gid, id)
)
SELECT gid, id, array_agg(id) OVER w
FROM data
WINDOW w AS (
 PARTITION BY gid
 ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING
 AFTER MATCH SKIP TO NEXT ROW
 PATTERN (A+)
 DEFINE A AS id < 10
);

-- 제한된 프레임에서의 흡수 테스트
WITH frame_absorb_test AS (
 SELECT * FROM (VALUES
  (0, 'A'), (1, 'A'), (2, 'A'), (3, 'B')
 ) AS t(id, flag)
)
SELECT id, flag, first_value(id) OVER w AS match_start, last_value(id) OVER w AS match_end
FROM frame_absorb_test
WINDOW w AS (
 ORDER BY id
 ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (A+ B)
 DEFINE
  A AS flag = 'A',
  B AS flag = 'B'
);

-- ROWS BETWEEN CURRENT ROW AND offset FOLLOWING
SELECT company, tdate, price, first_value(tdate) OVER w, last_value(tdate) OVER w,
 count(*) OVER w
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (START UP+ DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

--
-- 집계
--

-- AFTER MATCH SKIP PAST LAST ROW를 사용
SELECT company, tdate, price,
 first_value(price) OVER w,
 last_value(price) OVER w,
 max(price) OVER w,
 min(price) OVER w,
 sum(price) OVER w,
 avg(price) OVER w,
 count(price) OVER w
FROM rpr_price
WINDOW w AS (
PARTITION BY company
ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
AFTER MATCH SKIP PAST LAST ROW
INITIAL
PATTERN (START UP+ DOWN+)
DEFINE
START AS TRUE,
UP AS price > PREV(price),
DOWN AS price < PREV(price)
);

-- AFTER MATCH SKIP TO NEXT ROW를 사용
SELECT company, tdate, price,
 first_value(price) OVER w,
 last_value(price) OVER w,
 max(price) OVER w,
 min(price) OVER w,
 sum(price) OVER w,
 avg(price) OVER w,
 count(price) OVER w
FROM rpr_price
WINDOW w AS (
PARTITION BY company
ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
AFTER MATCH SKIP TO NEXT ROW
INITIAL
PATTERN (START UP+ DOWN+)
DEFINE
START AS TRUE,
UP AS price > PREV(price),
DOWN AS price < PREV(price)
);

-- RPR 축소된 프레임 안의 row_number()
SELECT company, tdate, price, row_number() OVER w, count(*) OVER w
FROM rpr_price
WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (START UP+ DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

--
-- SQL 통합: JOIN, CTE, LATERAL
--

-- JOIN 사례
CREATE TEMP TABLE rpr_join_left (i int, v1 int);
CREATE TEMP TABLE rpr_join_right (j int, v2 int);
INSERT INTO rpr_join_left VALUES(1,10);
INSERT INTO rpr_join_left VALUES(1,11);
INSERT INTO rpr_join_left VALUES(1,12);
INSERT INTO rpr_join_right VALUES(2,10);
INSERT INTO rpr_join_right VALUES(2,11);
INSERT INTO rpr_join_right VALUES(2,12);

SELECT * FROM rpr_join_left, rpr_join_right WHERE rpr_join_left.v1 <= 11 AND rpr_join_right.v2 <= 11;

SELECT *, count(*) OVER w FROM rpr_join_left, rpr_join_right
WINDOW w AS (
 PARTITION BY rpr_join_left.i
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (A)
 DEFINE
 A AS v1 <= 11 AND v2 <= 11
);

-- WITH 사례
WITH wstock AS (
  SELECT * FROM rpr_price WHERE tdate < '2023-07-08'
)
SELECT tdate, price,
first_value(tdate) OVER w,
count(*) OVER w
 FROM wstock
 WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UP+ DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- ReScan 테스트: LATERAL 조인이 RPR과 함께 WindowAgg 재스캔을 강제한다
SELECT g.x, sub.*
FROM generate_series(1, 2) g(x),
LATERAL (
  SELECT id, price, count(*) OVER w AS c
  FROM (VALUES (1, 100), (2, 200), (3, 150)) AS t(id, price)
  WHERE id <= g.x + 1
  WINDOW w AS (
    ORDER BY id
    ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    PATTERN (START UP+)
    DEFINE
      START AS TRUE,
      UP AS price > PREV(price)
  )
) sub
ORDER BY g.x, sub.id;

-- PREV가 여러 컬럼 참조를 가짐
CREATE TEMP TABLE rpr_prev_multicol (id INTEGER, i SERIAL, j INTEGER);
INSERT INTO rpr_prev_multicol(id, j) SELECT 1, g*2 FROM generate_series(1, 10) AS g;
SELECT id, i, j, count(*) OVER w
 FROM rpr_prev_multicol
 WINDOW w AS (
 PARTITION BY id
 ORDER BY i
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 INITIAL
 PATTERN (START COND+)
 DEFINE
  START AS TRUE,
  COND AS PREV(i + j + 1) < 10
);

--
-- 대규모 / 확장성 테스트
--

-- 더 큰 파티션에 대한 스모크 테스트.
WITH s AS (
 SELECT v, count(*) OVER w AS c
 FROM (SELECT generate_series(1, 5000) v)
 WINDOW w AS (
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  AFTER MATCH SKIP PAST LAST ROW
  INITIAL
  PATTERN ( r+ )
  DEFINE r AS TRUE
 )
)
-- 모든 행에 걸친 하나의 긴 매치여야 한다.
SELECT * FROM s WHERE c > 0;

WITH s AS (
 SELECT v, count(*) OVER w AS c
 FROM (SELECT generate_series(1, 5000) v)
 WINDOW w AS (
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  AFTER MATCH SKIP PAST LAST ROW
  INITIAL
  PATTERN ( r )
  DEFINE r AS TRUE
 )
)
-- 각 행은 자기만의 매치여야 한다.
SELECT count(*) FROM s WHERE c > 0;

-- 대형 파티션 테스트: A+ B* C{10000,} 패턴을 가진 10만 행 대량 반복에서 int32
-- 카운트가 오버플로하지 않는지 테스트한다
WITH data AS (
 SELECT generate_series(0, 100000) AS v
),
result AS (
 SELECT v,
        count(*) OVER w AS match_len,
        first_value(v) OVER w AS match_first,
        last_value(v) OVER w AS match_last
 FROM data
 WINDOW w AS (
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  AFTER MATCH SKIP PAST LAST ROW
  INITIAL
  PATTERN (A+ B* C{10000,})
  DEFINE
   A AS v < 33333,
   B AS v >= 33333 AND v < 66666,
   C AS v >= 66666 AND v < 99999
 )
)
-- 매치되어야 함: A (33333 행) + B (33333 행) + C (33333 행) = 99999 행
SELECT match_first, match_last, match_len FROM result WHERE match_len > 0;

-- JIT PREV/NEXT 내비게이션 테스트: DEFINE에 PREV가 있는 10만 행.
-- EEOP_RPR_NAV_SET/RESTORE JIT 코드 경로(has_rpr_nav 재적재)를 대규모로
-- 실행한다.  단일 V형: price가 중간 지점에서 0까지 떨어졌다가 다시 오른다.
SET jit = on;
SET jit_above_cost = 0;
WITH data AS (
 SELECT i, abs(50000 - i) AS price
 FROM generate_series(1, 100000) i
),
result AS (
 SELECT i, price,
        count(*) OVER w AS match_len,
        first_value(price) OVER w AS match_first
 FROM data
 WINDOW w AS (
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  AFTER MATCH SKIP PAST LAST ROW
  INITIAL
  PATTERN (DOWN+ UP+)
  DEFINE
   DOWN AS price < PREV(price),
   UP AS price > PREV(price)
 )
)
SELECT count(*) AS matched_rows, max(match_len) AS longest_match
FROM result WHERE match_len > 0;
RESET jit_above_cost;
RESET jit;

-- JIT 복합 내비게이션 테스트
SET jit = on;
SET jit_above_cost = 0;
SELECT count(*) AS matched_rows
FROM (
 SELECT v, count(*) OVER w AS match_len
 FROM generate_series(1, 1000) AS t(v)
 WINDOW w AS (
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  AFTER MATCH SKIP PAST LAST ROW
  PATTERN (A B+)
  DEFINE A AS TRUE, B AS PREV(FIRST(v), 1) > 0
 )
) sub WHERE match_len > 0;
RESET jit_above_cost;
RESET jit;

--
-- IGNORE NULLS
--

-- NULL 행이 없는 경우.  결과는 "basic test using PREV"와 동일해야 한다
SELECT company, tdate, price, first_value(price) IGNORE NULLS OVER w,
 last_value(price) IGNORE NULLS OVER w,
 nth_value(tdate, 2) IGNORE NULLS OVER w AS nth_second
 FROM rpr_price
 WINDOW w AS (
 PARTITION BY company
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 INITIAL
 PATTERN (START UP+ DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- IGNORE NULLS 옵션을 가진 nth_value 는 두 번째 행을 찾으려 하지만 중간의 NULL
-- 때문에 세 번째 행을 반환한다.
WITH data AS (
 SELECT * FROM (VALUES
  (10, 1), (11, NULL), (12, 3), (13, 4)
  ) AS t(gid, id))
  SELECT gid, id, nth_value(id, 2) IGNORE NULLS OVER w AS second_val,
  array_agg(id) OVER w
  FROM data
  WINDOW w AS (
   ORDER BY gid
   ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
   AFTER MATCH SKIP PAST LAST ROW
   PATTERN (A+)
   DEFINE A AS gid < 13
  );

-- IGNORE NULLS 옵션을 가진 nth_value 는 세 번째 행을 찾으려 하지만 중간의 NULL
-- 때문에 축소된 프레임의 끝에 도달하여 NULL을 반환한다
WITH data AS (
 SELECT * FROM (VALUES
  (10, 1), (11, NULL), (12, 3), (13, 4)
  ) AS t(gid, id))
  SELECT gid, id, nth_value(id, 3) IGNORE NULLS OVER w AS thrid_val,
  array_agg(id) OVER w
  FROM data
  WINDOW w AS (
   ORDER BY gid
   ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
   AFTER MATCH SKIP PAST LAST ROW
   PATTERN (A+)
   DEFINE A AS gid < 13
  );

-- IGNORE NULLS에서 축소된 프레임을 벗어난 nth_value
SELECT company, tdate, price,
 nth_value(price, 5) IGNORE NULLS OVER w AS nth_5_in
FROM rpr_price
WINDOW w AS (
 PARTITION BY company
 ORDER BY tdate
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (START UP+ DOWN+)
 DEFINE
  START AS TRUE,
  UP AS price > PREV(price),
  DOWN AS price < PREV(price)
);

-- IGNORE NULLS + 축소된 프레임의 첫 값이 NULL인 first_value
WITH data AS (
 SELECT * FROM (VALUES
  (1, NULL), (2, NULL), (3, 30), (4, 40)
 ) AS t(id, val))
SELECT id, val,
 first_value(val) IGNORE NULLS OVER w AS fv_ignull,
 count(*) OVER w
FROM data
WINDOW w AS (
 ORDER BY id
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (A+)
 DEFINE A AS TRUE
);

-- IGNORE NULLS + 축소된 프레임의 모든 값이 NULL
WITH data AS (
 SELECT * FROM (VALUES
  (1, NULL), (2, NULL), (3, NULL)
 ) AS t(id, val))
SELECT id, val,
 first_value(val) IGNORE NULLS OVER w AS fv_ignull,
 last_value(val) IGNORE NULLS OVER w AS lv_ignull,
 count(*) OVER w
FROM data
WINDOW w AS (
 ORDER BY id
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (A+)
 DEFINE A AS TRUE
);

--
-- 축소된 프레임이 NULL로 끝날 때의 last_value IGNORE NULLS non-NULL 값 탐색은
-- 전체 프레임이 아니라 축소된 프레임의 끝에서 시작해야 하므로, 뒤쪽의
-- non-NULL인 4 번 행은 반환되지 않는다
--
CREATE TEMP TABLE rpr_nullval (id INT, val INT);
INSERT INTO rpr_nullval VALUES (1, 10), (2, NULL), (3, NULL), (4, 20);

SELECT id, val,
       last_value(val) IGNORE NULLS OVER w AS lv_ignull,
       count(*) OVER w AS cnt
FROM rpr_nullval
WINDOW w AS (
  ORDER BY id
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  AFTER MATCH SKIP PAST LAST ROW
  PATTERN (A B+)
  DEFINE
    A AS val IS NOT NULL,
    B AS val IS NULL
);

--
-- NULL 오프셋을 가진 nth_value
--

CREATE TABLE rpr_dormant (id int, price int);
INSERT INTO rpr_dormant SELECT g, g*10 FROM generate_series(1,60) g;

-- 참고: first_value(id)는 현재 행에서 시작하는 매치의 시작 행이고, count(*)는
-- 축소된 프레임에 걸친 그 매치의 길이다
SELECT * FROM (
  SELECT id, first_value(id) OVER w AS match_start, count(*) OVER w AS match_len
  FROM rpr_dormant
  WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
    AFTER MATCH SKIP PAST LAST ROW
    PATTERN (A+) DEFINE A AS price > PREV(FIRST(price), 50))
) s WHERE id > 50 ORDER BY id;

-- NULL 오프셋을 가진 nth_value; DEFINE의 FIRST 내비게이션, SKIP PAST LAST ROW
SELECT * FROM (
  SELECT id, nv FROM (
    SELECT id, nth_value(price, CASE WHEN id < 50 THEN NULL ELSE 1 END) OVER w AS nv
    FROM rpr_dormant
    WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
      AFTER MATCH SKIP PAST LAST ROW
      PATTERN (A+) DEFINE A AS price > PREV(FIRST(price), 50))
  ) s
) t WHERE id > 50 ORDER BY id;

-- nth_value 와 함께 first_value, count를 둔 같은 윈도우
SELECT * FROM (
  SELECT id, nv, fv, cnt FROM (
    SELECT id, nth_value(price, CASE WHEN id < 50 THEN NULL ELSE 1 END) OVER w AS nv,
               first_value(id) OVER w AS fv, count(*) OVER w AS cnt
    FROM rpr_dormant
    WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
      AFTER MATCH SKIP PAST LAST ROW
      PATTERN (A+) DEFINE A AS price > PREV(FIRST(price), 50))
  ) s
) t WHERE id > 50 ORDER BY id;

-- 내비게이션이 없는 DEFINE에서의 같은 nth_value
SELECT * FROM (
  SELECT id, nv FROM (
    SELECT id, nth_value(price, CASE WHEN id < 50 THEN NULL ELSE 1 END) OVER w AS nv
    FROM rpr_dormant
    WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
      AFTER MATCH SKIP PAST LAST ROW
      PATTERN (A+) DEFINE A AS price > 0)
  ) s
) t WHERE id > 50 ORDER BY id;

-- PREV만 있는 DEFINE에서의 같은 nth_value (FIRST 내비게이션 없음)
SELECT * FROM (
  SELECT id, nv FROM (
    SELECT id, nth_value(price, CASE WHEN id < 50 THEN NULL ELSE 1 END) OVER w AS nv
    FROM rpr_dormant
    WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
      AFTER MATCH SKIP PAST LAST ROW
      PATTERN (A+) DEFINE A AS price > PREV(price, 50))
  ) s
) t WHERE id > 50 ORDER BY id;

-- 파티션 중간에 NULL 오프셋 구간이 있는 nth_value
SELECT * FROM (
  SELECT id, nv FROM (
    SELECT id, nth_value(price, CASE WHEN id BETWEEN 20 AND 40 THEN NULL ELSE 1 END) OVER w AS nv
    FROM rpr_dormant
    WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
      AFTER MATCH SKIP PAST LAST ROW
      PATTERN (A+) DEFINE A AS price > PREV(FIRST(price), 50))
  ) s
) t WHERE id BETWEEN 38 AND 46 ORDER BY id;

DROP TABLE rpr_dormant;

--
-- NULL 처리
--

CREATE TEMP TABLE rpr_stock_null (company TEXT, tdate DATE, price INTEGER);
INSERT INTO rpr_stock_null VALUES ('c1', '2023-07-01', 100);
INSERT INTO rpr_stock_null VALUES ('c1', '2023-07-02', NULL);  -- 중간의 NULL
INSERT INTO rpr_stock_null VALUES ('c1', '2023-07-03', 200);
INSERT INTO rpr_stock_null VALUES ('c1', '2023-07-04', 150);

SELECT company, tdate, price, count(*) OVER w AS match_count
FROM rpr_stock_null
WINDOW w AS (
  PARTITION BY company
  ORDER BY tdate
  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
  PATTERN (START UP DOWN)
  DEFINE START AS TRUE, UP AS price > PREV(price), DOWN AS price <
PREV(price)
);

-- 연속된 NULL: PREV가 NULL 값을 통과해 내비게이션한다
CREATE TEMP TABLE rpr_consec_null (id INT, val INT);
INSERT INTO rpr_consec_null VALUES
 (1, 100), (2, NULL), (3, NULL), (4, NULL), (5, 200), (6, 300);

-- 이전 행이 진짜 NULL이면 PREV(val) IS NULL은 참이다
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_consec_null
WINDOW w AS (
 ORDER BY id
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (A B+ C)
 DEFINE
  A AS val IS NULL,
  B AS val IS NULL AND PREV(val) IS NULL,
  C AS val IS NOT NULL
);

-- 연속된 NULL을 통과하는 NEXT(val)
SELECT id, val, count(*) OVER w AS cnt
FROM rpr_consec_null
WINDOW w AS (
 ORDER BY id
 ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
 AFTER MATCH SKIP PAST LAST ROW
 PATTERN (A B+ C)
 DEFINE
  A AS val IS NOT NULL,
  B AS val IS NULL AND NEXT(val) IS NULL,
  C AS val IS NULL AND NEXT(val) IS NOT NULL
);

DROP TABLE rpr_consec_null;

-- ============================================================
-- 주가 시나리오 테스트 (1632 행, 파티션된 지역)
-- ============================================================

-- 연속 상승일: 7 일 이상의 연속 구간을 찾는다
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (UP{7,})
        DEFINE UP AS price > PREV(price)
    )
) t WHERE days > 0 ORDER BY start_rn;

-- V자형 반등: 4 일 이상 하락 후 4 일 이상 상승
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(price) OVER w AS start_price,
           last_value(price) OVER w AS end_price,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (DECLINE{4,} RISE{4,})
        DEFINE
            DECLINE AS price < PREV(price),
            RISE AS price > PREV(price)
    )
) t WHERE days > 0 ORDER BY start_rn;

-- W자형 바닥: 하락, 반등, 재하락, 회복
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(price) OVER w AS start_price,
           last_value(price) OVER w AS end_price,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (DECLINE{3,} BOUNCE{3,} DIP{3,} RECOVER{3,})
        DEFINE
            DECLINE AS price < PREV(price),
            BOUNCE AS price > PREV(price),
            DIP AS price < PREV(price),
            RECOVER AS price > PREV(price)
    )
) t WHERE days > 0 ORDER BY start_rn;

-- 거래량 급증 구간: 거래량이 증가하는 6 일 이상의 연속 구간
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(volume) OVER w AS start_vol,
           last_value(volume) OVER w AS end_vol,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (INIT SURGE{5,})
        DEFINE
            SURGE AS volume > PREV(volume)
    )
) t WHERE days > 0 ORDER BY start_rn;

-- 변동성 수축: 일일 가격 범위가 연속으로 좁아짐
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(high - low) OVER w AS start_range,
           last_value(high - low) OVER w AS end_range,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (INIT NARROW{5,})
        DEFINE
            NARROW AS (high - low) < PREV(high) - PREV(low)
    )
) t WHERE days > 0 ORDER BY start_rn;

-- 갭 상승: 시가가 전일 종가보다 크게 높음 (5% 이상)
SELECT * FROM (
    SELECT first_value(rn) OVER w AS gap_rn,
           first_value(price) OVER w AS prev_close,
           last_value(open) OVER w AS gap_open,
           count(*) OVER w AS cnt
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (PREV_DAY GAP_UP)
        DEFINE
            GAP_UP AS open > PREV(price) * 1.05
    )
) t WHERE cnt > 0 ORDER BY gap_rn;

-- 가격-거래량 다이버전스: 가격은 상승하는데 거래량은 감소 (약세 신호)
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(price) OVER w AS start_price,
           last_value(price) OVER w AS end_price,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (INIT DIVERGE{3,})
        DEFINE
            DIVERGE AS price > PREV(price) AND volume < PREV(volume)
    )
) t WHERE days > 0 ORDER BY start_rn;

-- 통합 후 돌파: 횡보 후 급격한 상승
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(price) OVER w AS start_price,
           last_value(price) OVER w AS end_price,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (FLAT{5,} BREAKOUT)
        DEFINE
            FLAT AS price BETWEEN PREV(price) * 0.98 AND PREV(price) * 1.02,
            BREAKOUT AS price > PREV(price) * 1.05
    )
) t WHERE days > 0 ORDER BY start_rn;

-- 데드 캣 바운스: 하락 후 약한 회복 (일일 1% 미만)
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(price) OVER w AS start_price,
           last_value(price) OVER w AS end_price,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (DECLINE{4,} BOUNCE{3,})
        DEFINE
            DECLINE AS price < PREV(price),
            BOUNCE AS price > PREV(price) AND price < PREV(price) * 1.01
    )
) t WHERE days > 0 ORDER BY start_rn;

-- 상승 추세: 고점과 저점이 모두 높아지는 7 일 이상의 연속 구간
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(price) OVER w AS start_price,
           last_value(price) OVER w AS end_price,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (UPTREND{7,})
        DEFINE
            UPTREND AS high > PREV(high) AND low > PREV(low)
    )
) t WHERE days > 0 ORDER BY start_rn;

-- 패닉과 급반등: 일일 3% 이상 하락 후 2% 이상 반등
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(price) OVER w AS start_price,
           last_value(price) OVER w AS end_price,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (PANIC{2,} SNAP)
        DEFINE
            PANIC AS price < PREV(price) * 0.97,
            SNAP AS price > PREV(price) * 1.02
    )
) t WHERE days > 0 ORDER BY start_rn;

-- 거래량 클라이맥스 반전: 상승 추세, 거래량 급증(1.5배), 이후 하락
SELECT * FROM (
    SELECT first_value(rn) OVER w AS start_rn,
           last_value(rn) OVER w AS end_rn,
           first_value(price) OVER w AS start_price,
           last_value(price) OVER w AS end_price,
           count(*) OVER w AS days
    FROM rpr_stock
    WINDOW w AS (
        PARTITION BY part_id
        ORDER BY rn
        ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING
        AFTER MATCH SKIP PAST LAST ROW
        PATTERN (RALLY{3,} CLIMAX SELLOFF{2,})
        DEFINE
            RALLY AS price > PREV(price),
            CLIMAX AS volume > PREV(volume) * 1.5,
            SELLOFF AS price < PREV(price)
    )
) t WHERE days > 0 ORDER BY start_rn;
