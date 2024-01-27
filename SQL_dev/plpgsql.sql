/* Хранимая процедура, обновляющая почасовую ставку сотрудников на определённый процент. 
 * Минимальная ставка — 500 рублей в час. 
 */
CREATE OR REPLACE PROCEDURE update_employees_rate(in JSON)
LANGUAGE plpgsql
AS $$
DECLARE 
	p_rate TEXT;
	p_employee_id TEXT;
BEGIN
	FOR _i IN 0..JSON_ARRAY_LENGTH($1)-1 LOOP
		p_rate := $1->_i->>'rate_change';
		p_employee_id := $1->_i->>'employee_id';
		UPDATE employees
		SET rate=CASE 
					WHEN (1+p_rate::NUMERIC/100)*rate<500 
					THEN 500 
					ELSE (1+p_rate::NUMERIC/100)*rate
					END
		WHERE id=p_employee_id::UUID;
	END LOOP;
END;
$$;

/* Хранимая процедура, повышающая зарплаты всех сотрудников на определённый процент. 
 * Сотрудникам, которые получают зарплату по ставке ниже средней относительно всех сотрудников до индексации, начисляют дополнительные 2%. 
*/
CREATE OR REPLACE PROCEDURE indexing_salary(p INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
	mean_salary NUMERIC;
BEGIN
	SELECT AVG(rate) INTO mean_salary
	FROM employees;
	
	UPDATE employees
	SET rate = CASE 
					WHEN rate<mean_salary
					THEN rate*(1+(p+2)::NUMERIC/100)
					ELSE 
					rate*(1+p::NUMERIC/100)
				END;
END;				
$$;

-- Пользовательская процедура завершения проекта
CREATE OR REPLACE PROCEDURE close_project(UUID)
LANGUAGE plpgsql
AS $$
DECLARE
	bonus RECORD;
	status boolean;
BEGIN

	SELECT is_active INTO status
	FROM projects
	WHERE id=$1;
	
	IF NOT status
	THEN 
	RAISE EXCEPTION 'Project closed';
	END IF;

	UPDATE projects
	SET is_active = FALSE
	WHERE id=$1;
	
	SELECT 
	p.id,
	COUNT(DISTINCT l.employee_id),
	FLOOR(0.75*(p.estimated_time - SUM(l.work_hours))/COUNT(DISTINCT l.employee_id)) bon INTO bonus
	FROM projects p
	JOIN logs l ON l.project_id=p.id
	WHERE p.id=$1
	GROUP BY 1;
	
	IF (bonus.bon IS NOT NULL) AND (bonus.bon > 0)
	THEN 
	INSERT INTO logs(id, employee_id, project_id, work_date, work_hours)
	SELECT DISTINCT
	GEN_RANDOM_UUID(),
	employee_id,
	project_id,
	CURRENT_DATE,
	CASE 
		WHEN bonus.bon > 16
		THEN 16
		ELSE bonus.bon
	END
	FROM logs
	WHERE project_id=$1;
	END IF;
	
END;
$$;

-- Процедура, добавляющая новые записи о работе сотрудников над проектами.

CREATE OR REPLACE PROCEDURE log_work(p_employee_id UUID, p_project_id UUID, p_date DATE, p_hours INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE 
	status BOOLEAN;
BEGIN
	
	SELECT is_active INTO status
	FROM projects
	WHERE id=p_project_id;
	
	IF NOT status -- прерывание функции при закрытом проекте
	THEN RAISE EXCEPTION 'Project closed';	
	ELSIF (p_hours<1) OR (p_hours>24) -- прерывании функции при неверно заданном времени
	THEN RAISE EXCEPTION 'Hours out of bounds';
	ELSIF (p_hours > 16) OR (p_date>CURRENT_DATE) OR (p_date<CURRENT_DATE-INTERVAL'1 W')
	THEN 	
		INSERT INTO logs(id, employee_id, project_id, work_date, work_hours, required_review)
		VALUES(GEN_RANDOM_UUID(),p_employee_id,p_project_id,p_date,p_hours,true);
	ELSE
		INSERT INTO logs(id, employee_id, project_id, work_date, work_hours)
		VALUES(GEN_RANDOM_UUID(),p_employee_id,p_project_id,p_date,p_hours);
	END IF;
	
END;
$$;

-- При добавлении сотрудника в таблицу employees и изменении ставки сотрудника триггер автоматически вносит запись в таблицу employees.

CREATE TABLE IF NOT EXISTS employee_rate_history(
	id UUID DEFAULT GEN_RANDOM_UUID(),
	employee_id UUID REFERENCES employees,
	rate INTEGER,
	from_date DATE
);

INSERT INTO employee_rate_history(employee_id,rate,from_date)
SELECT 
id, 
rate,
'2020-12-26'
FROM employees;

CREATE OR REPLACE FUNCTION save_employee_rate_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
	INSERT INTO employee_rate_history(employee_id,rate,from_date)
	VALUES(NEW.id,NEW.rate,CURRENT_DATE);
	RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER change_employee_rate
AFTER INSERT OR UPDATE 
ON employees
FOR EACH ROW
EXECUTE FUNCTION save_employee_rate_history();

-- Функция возвращает таблицу с именами трёх сотрудников, которые залогировали максимальное количество часов в проекте. 

CREATE OR REPLACE FUNCTION best_project_workers(UUID)
RETURNS TABLE(name TEXT, total_hours BIGINT)
LANGUAGE plpgsql
AS $$
BEGIN
	RETURN QUERY
	SELECT 
	e.name, 
	SUM(l.work_hours) hours_total
	FROM logs l
	JOIN employees e ON l.employee_id = e.id
	WHERE l.project_id=$1
	GROUP BY 1
	ORDER BY hours_total DESC, COUNT(*) DESC
	LIMIT 3;
END;
$$;

-- Функция для расчета среднемесячной зарплаты.

CREATE OR REPLACE FUNCTION calculate_month_salary(date_begin DATE, date_end DATE)
RETURNS TABLE(id UUID, worked_hours BIGINT, salary NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE 
	_r RECORD;
BEGIN
	FOR _r IN 
	WITH t AS (
		SELECT 
		employee_id, 
		required_review,
		SUM(work_hours) total_hours,
		CASE
			WHEN SUM(work_hours)>160
			THEN SUM(work_hours) - 160
			ELSE 0
		END extra_time -- время, рассчитываемое по повышенной ставке.
		FROM logs
		WHERE work_date BETWEEN date_begin AND date_end
		AND NOT is_paid
		GROUP BY 1,2)
	SELECT 
	t.employee_id, 
	t.total_hours, 
	e.rate*((t.total_hours-t.extra_time)+t.extra_time*1.25) salary, -- переработки считаются с кэфом 1.25
	t.required_review 
	FROM t
	JOIN employees e ON t.employee_id=e.id LOOP
		IF _r.required_review
		THEN RAISE NOTICE 'Warning! Employee % hours must be reviewed!',_r.employee_id;
		id:=_r.employee_id;
		worked_hours:=_r.total_hours;
		salary:=_r.salary;
		RETURN NEXT;
		ELSE
		id:=_r.employee_id;
		worked_hours:=_r.total_hours;
		salary:=_r.salary;
		RETURN NEXT;
		END IF;
	END LOOP;
END;
$$;

SELECT * FROM heap_page_items(get_raw_page('t', 0));

CREATE TABLE t (id INTEGER, name VARCHAR);
INSERT INTO t VALUES (1,'AND')

UPDATE t SET id=2;