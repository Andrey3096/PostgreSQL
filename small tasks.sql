-- 1
create or replace function max_value(in p_number integer)
returns integer
language plpgsql 
as 
$$
declare
	p_sum integer;
begin
	with recursive r as (
		select 0 as a, 1 as b, 0 as sum
		union
		select a + 1 as a, b + 1 as b, a*b as sum
		from r
		where a*b<p_number
		)
		select max(sum) into p_sum from r;
		return p_sum;
end;
$$;

create temp table posts as select now()-
  (interval'10000min'*random()) as created_at,
 generate_series(1,(5000*random())::int) id;

-- 2
create or replace function n_perpendicular_intersections(n integer)
returns integer
language plpgsql
as $$
declare
	result integer := 0;
	add_to_res integer := 0;
begin 
	for perpendiculars in 1..n loop
		if mod(perpendiculars,2)=0 then 
			add_to_res := add_to_res + 1;
			result = result + add_to_res;
		else
			result = result + add_to_res;
		end if;
	end loop;
	return result;
end;
$$;

select n_perpendicular_intersections(8);

-- 3
create or replace function spaceshift_cmp(a text, b text) -- spaceshift operator for text
returns text
as $$
select 
case
	when a < b then 'Less'
	when a > b then 'Greater'
	else 'Equal'
end;
$$ language sql strict immutable;

create operator #<=>#(
leftarg=text,
rightarg=text,
function=spaceshift_cmp 
);

select 'a' #<=># 'b'; -- Less

create or replace function spaceshift_cmp(a integer, b integer) -- spaceshift operator for integer
returns text
as $$
select 
case
	when a < b then 'Less'
	when a > b then 'Greater'
	else 'Equal'
end;
$$ language sql strict immutable;

create operator #<=>#(
leftarg=integer,
rightarg=integer,
function=spaceshift_cmp 
);

select 2 #<=># 1; -- Greater

create or replace function spaceshift_cmp(a timestamptz, b timestamptz) -- spaceshift operator for timestampz data type/also operator defined for timestamp 
returns text
as $$
select 
case
	when a < b then 'Less'
	when a > b then 'Greater'
	else 'Equal'
end;
$$ language sql strict immutable;

create operator #<=>#(
leftarg=timestamptz,
rightarg=timestamptz,
function=spaceshift_cmp 
);

select now() #<=># now()-interval'1 day'; -- Greater

create or replace function spaceshift_cmp(a date, b date) -- spaceshift operator for date
returns text
as $$
select 
case
	when a < b then 'Less'
	when a > b then 'Greater'
	else 'Equal'
end;
$$ language sql strict immutable;

create operator #<=>#(
leftarg=date,
rightarg=date,
function=spaceshift_cmp 
);

select '2024-02-01'::date#<=>#'2024-01-01'::date; -- Greater

create or replace function spaceshift_cmp(a numeric, b numeric) -- spaceshift operator for numeric
returns text
as $$
select 
case
	when a < b then 'Less'
	when a > b then 'Greater'
	else 'Equal'
end;
$$ language sql strict immutable;

create operator #<=>#(
leftarg=numeric,
rightarg=numeric,
function=spaceshift_cmp 
);

select 1.1::numeric #<=># 1.2::numeric

create or replace function spaceshift_cmp(a date[], b date[]) -- spaceshift operator for numeric/text/integer/timestamptz/date arrays
returns text
as $$
select 
case
	when a < b then 'Less'
	when a > b then 'Greater'
	else 'Equal'
end;
$$ language sql strict immutable;

create operator #<=>#(
leftarg=date[],
rightarg=date[],
function=spaceshift_cmp 
);

select '{1,2,3}'#<=>#'{1,2,2,4}' -- Greater

-- 4
create table dividend as select case random() > 0.1 when true then
 now() + (100 *random() - random()*100) * interval '1 day' else null
 end dividend_time, generate_series(11,111)%10 client_id;
 
create table client as (select generate_series(0,10) client_id,
 null::timestamp dividend_time);
 
with determine_future_dividend_cte as (
	select 
	client_id,
	dividend_time,
	case 
		when dividend_time - now() >= interval'0 days' then true
		when dividend_time - now() < interval'0 days' then false
		else null
	end is_future_dividend_exists
	from dividend), display_dividend_cte as (
		select 
		client_id, 
		is_future_dividend_exists,
		case 
			when is_future_dividend_exists then min(dividend_time)
			when not is_future_dividend_exists then max(dividend_time)
			else '1970-01-01 00:00:00'
		end displayed_dividend
		from determine_future_dividend_cte
		group by client_id,is_future_dividend_exists
		order by client_id,is_future_dividend_exists
		), ranking_dividends_cte as(
			select client_id, displayed_dividend, rank() over(partition by client_id order by displayed_dividend desc) as ranking_dividends
			from display_dividend_cte
		)
select client_id, displayed_dividend
from ranking_dividends_cte
where ranking_dividends = 1;

-- 5
create or replace function char_sum(varchar[]) -- function that is returning sum of letters in varchar array
returns varchar
language sql
as $$
	SELECT coalesce(chr(cast((sum(ascii(letter) - 96) - 1)%26 as int)+ 97), 'z') from unnest($1) as letter;
$$;

create or replace function string_sum(text) -- function that is returning sum of letters in string
returns varchar
language plpgsql
as $$
declare 
	string_array text[];
begin
	select regexp_split_to_array($1,'') into string_array;
	return char_sum(string_array);
end;
$$;

create or replace function string_arr_sum(text[]) -- function that is returning sum of letters in string array
returns varchar
language plpgsql
as $$
declare 
	s record;
	letters_array varchar[];
begin
	for s in select * from unnest($1) as t(string) loop
		letters_array := array_append(letters_array,string_sum(s.string));
	end loop;
	return char_sum(letters_array);
end;
$$;

select string_arr_sum(array['abc','ycb']); --j

-- 6
create table t1(id integer, name text);

begin; --T1
	update t1 set name = 'd' where id = 1; -- T1 acquires exclusive share lock of string with id=1

| begin -- T2
| 	update t1 set name = 'f' where id = 2; -- T2 acquires exclusive share lock of string with id=2
| 	update t1 set name = 'e' where id = 1; -- T2 waiting for end of T1
	update t1 set name = 'g' where id = 2; -- deadlock

/*SQL Error [40P01]: ERROR: deadlock detected
Подробности: Process 21708 waits for ShareLock on transaction 1782; blocked by process 83313.
Process 83313 waits for ShareLock on transaction 1781; blocked by process 21708.
Подсказка: See server log for query details.
Где: while updating tuple (0,6) in relation "t1" */

-- 7
with t as (
	select 
	date(created_at) dt,
	count(*) as cnt
	from posts
	group by date(created_at)
 )
select 
dt, 
cnt, 
sum(cnt) over(order by dt) 
from t;