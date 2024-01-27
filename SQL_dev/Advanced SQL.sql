CREATE TYPE cafe.restaurant_type AS ENUM 
    ('coffee_shop', 'restaurant', 'bar', 'pizzeria');

CREATE TABLE IF NOT EXISTS cafe.restaurants(
	restaurant_uuid uuid PRIMARY KEY DEFAULT GEN_RANDOM_UUID(), 
	name TEXT NOT NULL,
	location geometry(POINT) NOT NULL, -- предполагается небольшая удаленность ресторанов друг от друга в пределах Москвы, поэтому используется тип geometry.
	type cafe.restaurant_type NOT NULL,
	menu JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS cafe.managers(
	manager_uuid uuid PRIMARY KEY DEFAULT GEN_RANDOM_UUID(),
	name VARCHAR(40) NOT NULL,
	phone VARCHAR(20) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS cafe.restaurant_manager_work_dates(
	restaurant_uuid uuid REFERENCES cafe.restaurants,
	manager_uuid uuid REFERENCES cafe.managers,
	date_begin DATE NOT NULL,
	date_end DATE NOT NULL,
	PRIMARY KEY(restaurant_uuid,manager_uuid),
	CHECK(date_end>=date_begin)
);

CREATE TABLE IF NOT EXISTS cafe.sales(
	sales_date DATE,
	restaurant_uuid uuid REFERENCES cafe.restaurants,
	avg_check NUMERIC CHECK(avg_check>=0),
	PRIMARY KEY(sales_date,restaurant_uuid)
);

-- вспомогательная функция ST_MakePoint возвращает объект точку типа geometry, получая на вход долготу и широту.
INSERT INTO cafe.restaurants(name,location,type,menu)
SELECT DISTINCT 
s.cafe_name,
ST_SetSRID(ST_MakePoint(s.longitude,s.latitude),4326),
s.type::cafe.restaurant_type,
m.menu
FROM raw_data.menu m 
JOIN raw_data.sales s USING (cafe_name);

INSERT INTO cafe.managers(name, phone)
SELECT DISTINCT 
s.manager, 
s.manager_phone
FROM raw_data.sales s;

INSERT INTO cafe.restaurant_manager_work_dates(restaurant_uuid,manager_uuid,date_begin,date_end)
SELECT
    r.restaurant_uuid AS restaurant_uuid,
    m.manager_uuid AS manager_uuid,
    min(report_date) AS start_work,
    max(report_date) AS end_work
FROM raw_data.sales AS s
JOIN cafe.restaurants AS r ON s.cafe_name = r.name 
JOIN cafe.managers AS m ON s.manager = m.name 
GROUP BY 1,2;

INSERT INTO cafe.sales(sales_date,restaurant_uuid,avg_check)
SELECT s.report_date,
r.restaurant_uuid,
s.avg_check 
FROM raw_data.sales s
JOIN cafe.restaurants r ON s.cafe_name=r.name;

-- Представление, которое показывает топ-3 заведений внутри каждого типа заведения по среднему чеку за все даты. 
CREATE VIEW top_three_most_profitable_of_type AS(
WITH avg_check_calc AS (
	SELECT 
	r.name, 
	r.type, 
	AVG(s.avg_check) AS year_avg,
	ROW_NUMBER() OVER(PARTITION BY r.type ORDER BY AVG(s.avg_check) DESC) rank
	FROM cafe.sales s
	JOIN cafe.restaurants r USING (restaurant_uuid)
	GROUP BY 1,2)
SELECT 
	name, 
	type, 
	ROUND(year_avg,2) avg_check
FROM avg_check_calc
WHERE rank<4);

-- Материализованное представление, которое показывает, как изменяется средний чек для каждого заведения от года к году за все года за исключением 2023 года.
CREATE MATERIALIZED VIEW avg_check_pct_change AS (
WITH avg_check_calc AS (
	SELECT 
	EXTRACT('year' FROM s.sales_date) AS year_sales,
	r.name, 
	r.type, 
	ROUND(AVG(s.avg_check),2) AS year_avg
	FROM cafe.sales s
	JOIN cafe.restaurants r USING (restaurant_uuid)
	WHERE EXTRACT('year' FROM s.sales_date) != '2023'
	GROUP BY 1,2,3)
SELECT 
	year_sales,
	name, type, 
	year_avg, 
	LAG(year_avg) OVER(PARTITION BY name, type ORDER BY year_sales) AS prev_year, 
	ROUND((year_avg/LAG(year_avg) OVER(PARTITION BY name, type ORDER BY year_sales) - 1)*100,2) pct_change 
FROM avg_check_calc;
	
-- Топ-3 заведения, где чаще всего менялся менеджер за весь период.
SELECT name, COUNT(DISTINCT manager_uuid) cnt
FROM cafe.restaurant_manager_work_dates rm JOIN cafe.restaurants r USING(restaurant_uuid)
GROUP BY 1
ORDER BY 2 DESC
LIMIT 3;

-- Пиццерия с самым большим количеством пицц в меню.
WITH pizzas_in_restaurants AS (SELECT name,JSONB_EACH(menu->'Пицца')
						   FROM cafe.restaurants 
						   WHERE menu->'Пицца' IS NOT NULL), -- оставляем в выборке рестораны, в меню которых есть пицца.
		num_pizzas AS (SELECT name, COUNT(*) cnt
					   FROM pizzas_in_restaurants
					   GROUP BY 1),
			ranked_by_num_pizzas AS (SELECT name, cnt, DENSE_RANK() OVER(ORDER BY cnt DESC) rank_num
									 FROM num_pizzas)
SELECT name, cnt
FROM ranked_by_num_pizzas
WHERE rank_num=1;

-- Самая дорогая пицца для каждой пиццерии.
WITH menu_cte AS (
	SELECT q.name restaurant, 'Пицца' type,d.key AS pizza, d.value::int price 
	FROM cafe.restaurants q
	JOIN JSONB_EACH(menu->'Пицца') d ON True),
	menu_with_rank AS (
		SELECT restaurant, type, pizza, price, ROW_NUMBER() OVER(PARTITION BY restaurant ORDER BY price DESC) price_rank
		FROM menu_cte)
SELECT restaurant, type, pizza, price
FROM menu_with_rank
WHERE price_rank = 1;

-- Два самых близких друг к другу заведения одного типа.
SELECT 
r1.name name_1,
r2.name name_2,
r1.type,
min(ST_Distance(r1.location::geography,r2.location::geography)) distance
FROM cafe.restaurants r1,cafe.restaurants r2
WHERE r1.type=r2.type and r1.restaurant_uuid != r2.restaurant_uuid
GROUP BY 1,2,3
ORDER BY min(ST_Distance(r1.location::geography,r2.location::geography))
LIMIT 1;

-- Район с самым большим количеством заведений и район с самым маленьким количеством заведений.
WITH restaurants_in_district AS(
	SELECT DISTINCT 
	d.district_name, 
	COUNT(r.location) OVER(PARTITION BY d.district_name) cnt
	FROM cafe.districts d
	JOIN cafe.restaurants r ON ST_WITHIN(r.location,d.district_geom)), -- не включая рестораны на границах района
	sorted_restaurants_cnt AS(
		SELECT district_name, cnt, MIN(cnt) OVER() min_cnt, MAX(cnt) OVER() max_cnt
		FROM restaurants_in_district)
SELECT district_name, cnt
FROM sorted_restaurants_cnt
WHERE cnt IN(min_cnt, max_cnt)
ORDER BY 2 DESC;