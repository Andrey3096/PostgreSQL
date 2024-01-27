CREATE SCHEMA IF NOT EXISTS raw_data;

CREATE TABLE IF NOT EXISTS raw_data.sales(
    id INTEGER PRIMARY KEY,
    auto TEXT,
    gasoline_consumption NUMERIC(3,1),
    price NUMERIC(12,5),
    date DATE,
    person TEXT,
    phone TEXT,
    discount INTEGER,
    brand_origin TEXT
);

COPY raw_data.sales(id, auto, gasoline_consumption, price, date, person, phone, discount, brand_origin)
FROM '/Users/cars.csv' CSV HEADER NULL 'null'; -- пропуски обозначены в таблице 'null'

CREATE SCHEMA IF NOT EXISTS car_shop;

--Для приведения таблицы к 1НФ требуется разнести имя и фамилию покупателя по разным полям. 
CREATE TABLE IF NOT EXISTS car_shop.buyers(
	id SERIAL PRIMARY KEY,
	name VARCHAR(20) NOT NULL, 
	surname VARCHAR(40) NOT NULL, 
	phone VARCHAR(40) UNIQUE NOT NULL,
	CONSTRAINT buyers_name_surname_phone_unique UNIQUE(name, surname, phone)
);

/*
Для поля с полными именем отчищаю пробелы в начале и конце строки.
Разношу разделенные пробелом имена и фамилии в отдельные столбцы функцией SPLIT_PART.
*/
INSERT INTO car_shop.buyers(name, surname, phone)
SELECT SPLIT_PART(TRIM(person),' ',1), SPLIT_PART(TRIM(person),' ',2), phone
FROM raw_data.sales
group by 1,2,3
having count(*)=1; -- наполняю таблицу уникальными по имени,фамилии,номеру телефона строками.

/*
Для сохранения таблицы cars в 3НФ страна производителя выносится в отдельную таблицу.
В противном случае "origin" будет зависеть от части ключа "brand",что нарушает требования 2НФ.
*/
CREATE TABLE IF NOT EXISTS car_shop.origin(
	id SERIAL PRIMARY KEY,
	origin VARCHAR(40) UNIQUE
);
/*
gasoline_consumption, price - неключевые столбцы, зависящие от потенциального ключа (brand,model).
Они так же находятся в непосредственной зависимости от потенциального ключа.
Таблица находится в 3НФ.
*/
CREATE TABLE IF NOT EXISTS car_shop.cars(
	id SERIAL PRIMARY KEY,
	brand VARCHAR(20) NOT NULL,
	model VARCHAR(20) NOT NULL,
	gasoline_consumption numeric(3,1),
	origin_id INTEGER REFERENCES car_shop.origin,
	CONSTRAINT cars_brand_id_model_unique UNIQUE(brand,model)
);

CREATE TABLE IF NOT EXISTS car_shop.colors(
	id SERIAL PRIMARY KEY,
	color VARCHAR(20) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS car_shop.purchases(
	id SERIAL PRIMARY KEY,
	car_id INTEGER REFERENCES car_shop.cars,
	buyer_id INTEGER REFERENCES car_shop.buyers,
	date DATE NOT NULL,
	price NUMERIC(9,2) NOT NULL,
	color_id INTEGER REFERENCES car_shop.colors,
	discount INTEGER,
	CONSTRAINT purchases_carid_buyerid_date_colorid UNIQUE(car_id,buyer_id,date,color_id) -- связка car_id,buyer_id,date,color_id является потенциальным ключом.
); 

-- заполнение таблицы с цветами.
INSERT INTO car_shop.colors(color) 
SELECT DISTINCT SUBSTR(auto,STRPOS(auto,',')+1) from raw_data.sales;

-- заполнение таблицы с производителями.
INSERT INTO car_shop.origin(origin)
SELECT DISTINCT brand_origin from raw_data.sales;

-- заполнение данными таблицы car_shop.cars
INSERT INTO car_shop.cars(brand,model,gasoline_consumption,origin_id)
SELECT DISTINCT SPLIT_PART(s.auto,' ',1) AS brand, SUBSTRING(s.auto, STRPOS(s.auto,' '),STRPOS(s.auto,',')-STRPOS(s.auto,' ')) AS model,s.gasoline_consumption,o.id
FROM raw_data.sales s JOIN car_shop.origin o ON s.brand_origin=o.origin;

-- заполнение данными таблицы car_shop.purchases
INSERT INTO car_shop.purchases(car_id,buyer_id,date,color_id,price,discount)
SELECT c.id, b.id,s.date,col.id,ROUND(s.price,2),s.discount
FROM raw_data.sales s
JOIN car_shop.cars c ON SPLIT_PART(s.auto,' ',1)=c.brand and SUBSTRING(s.auto, STRPOS(s.auto,' '),STRPOS(s.auto,',')-STRPOS(s.auto,' ')) = c.model
JOIN car_shop.origin o ON o.id=c.origin_id
JOIN car_shop.colors col ON SUBSTR(s.auto,STRPOS(s.auto,',')+1)=col.color
JOIN car_shop.buyers b ON b."name"||' '||b.surname=s.person AND b.phone=s.phone;

/*

ЭТАП 2. СОЗДАНИЕ ВЫБОРОК

*/

--Запрос, который выведет процент моделей машин, у которых нет параметра gasoline_consumption.
SELECT ROUND(COUNT(gasoline_consumption)::NUMERIC/COUNT(1),2) FROM raw_data.sales;

-- Запрос, который покажет название бренда и среднюю цену его автомобилей в разбивке по всем годам с учётом скидки
SELECT c.brand, EXTRACT(year FROM p.date) AS year,ROUND(AVG(p.price),2)
FROM car_shop.purchases p JOIN car_shop.cars c ON p.car_id=c.id
GROUP BY 1,2
ORDER BY 1,2;

-- Расчет средней цены всех автомобилей с разбивкой по месяцам в 2022 году с учётом скидки
SELECT EXTRACT(month FROM p.date) AS month,EXTRACT(year FROM p.date) AS year,ROUND(AVG(p.price),2)
FROM car_shop.purchases p JOIN car_shop.cars c ON p.car_id=c.id
WHERE EXTRACT(year FROM p.date)='2022'
GROUP BY 1,2
ORDER BY 1;

-- Запрос, который выведет список купленных машин у каждого пользователя через запятую
SELECT b.name||' '||b.surname AS person, STRING_AGG(c.brand||' '||c.model,',') AS cars
FROM car_shop.purchases p 
JOIN car_shop.cars c ON p.car_id=c.id
JOIN car_shop.buyers b ON b.id=p.buyer_id
GROUP BY 1;

-- Запрос, который вернёт самую большую и самую маленькую цену продажи автомобиля с разбивкой по стране без учёта скидки
SELECT o.origin, 
ROUND(MAX(CASE WHEN p.discount = 0 THEN p.price ELSE p.price*100/(100-p.discount) END),2) AS max_price, 
ROUND(MIN(CASE WHEN p.discount = 0 THEN p.price ELSE p.price*100/(100-p.discount) END),2) AS min_price
FROM car_shop.purchases p
JOIN car_shop.cars c ON p.car_id=c.id
JOIN car_shop.origin o ON o.id=c.origin_id
GROUP BY 1;

-- Запрос, который покажет количество всех пользователей из США
SELECT COUNT(1) AS persons_from_usa_count FROM car_shop.buyers WHERE phone LIKE '+1%';