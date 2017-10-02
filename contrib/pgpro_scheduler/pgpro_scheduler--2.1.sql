\echo Use "CREATE EXTENSION pgpro_scheduler" to load this file. \quit

CREATE TYPE job_status_t AS ENUM ('working', 'done', 'error');
CREATE TYPE job_at_status_t AS ENUM ('submitted', 'processing', 'done');
CREATE SEQUENCE @extschema@.at_jobs_submitted_id_seq;

CREATE TABLE at_jobs_submitted(
   id bigint PRIMARY KEY,
   node text,
   name text,
   comments text,
   at timestamp with time zone,
   do_sql text,
   params text[],
   depends_on bigint[],
   executor text,
   owner text,
   last_start_available timestamp with time zone,
   attempt bigint default 0,
   resubmit_limit bigint default 100,
   postpone interval,
   max_run_time	interval,
   canceled boolean default false,
   submit_time timestamp with time zone default now()
);
CREATE INDEX ON at_jobs_submitted(at,submit_time);
CREATE INDEX ON at_jobs_submitted (last_start_available, node);

CREATE TABLE at_jobs_process  (like at_jobs_submitted including all);
ALTER TABLE at_jobs_process ADD start_time timestamp with time zone default now();
CREATE INDEX at_jobs_process_node_at_idx on at_jobs_process (node,  at);

CREATE TABLE at_jobs_done  (like at_jobs_process including all);
ALTER TABLE at_jobs_done ADD status boolean;
ALTER TABLE at_jobs_done ADD reason text;
ALTER TABLE at_jobs_done ADD done_time timestamp with time zone default now();

ALTER TABLE at_jobs_submitted ALTER id SET default nextval('@extschema@.at_jobs_submitted_id_seq');

CREATE TABLE cron(
   id SERIAL PRIMARY KEY,
   node text,
   name text,
   comments text,
   rule jsonb,
   next_time_statement text,
   do_sql text[],
   same_transaction boolean DEFAULT false,
   onrollback_statement text,
   active boolean DEFAULT true,
   broken boolean DEFAULT false,
   executor text,
   owner text,
   postpone interval,
   retry integer default 0,
   max_run_time	interval,
   max_instances integer default 1,
   start_date timestamp with time zone,
   end_date timestamp with time zone,
   reason text,
   _next_exec_time timestamp with time zone
);

CREATE INDEX ON cron (node);
CREATE INDEX ON cron (owner);
CREATE INDEX ON cron (executor);

CREATE TABLE at(
   start_at timestamp with time zone,
   last_start_available timestamp with time zone,
   retry integer,
   cron integer REFERENCES cron (id),
   node text,
   started timestamp with time zone,
   active boolean,
   PRIMARY KEY (start_at, cron)
);

CREATE TABLE log(
   start_at timestamp with time zone,
   last_start_available timestamp with time zone,
   retry integer,
   cron integer,
   node text,
   started timestamp with time zone,
   finished timestamp with time zone,
   status boolean,
   message text,
   PRIMARY KEY (start_at, cron)
);
CREATE INDEX log_cron_idx on log (cron);
CREATE INDEX log_cron_start_at_idx on log (cron, node, start_at);

---------------
--   TYPES   --
---------------

CREATE TYPE cron_rec AS(
	id integer,				-- job record id
	node text,				-- node name
	name text,				-- name of the job
	comments text,			-- comment on job
	rule jsonb,				-- rule of schedule
	commands text[],		-- sql commands to execute
	run_as text,			-- name of the executor user
	owner text,				-- name of the owner user
	start_date timestamp with time zone,	-- left bound of execution time window 
							-- unbound if NULL
	end_date timestamp with time zone,		-- right bound of execution time window
							-- unbound if NULL
	use_same_transaction boolean,	-- if true sequence of command executes 
									-- in a single transaction
	last_start_available interval,	-- time interval while command could 
									-- be executed if it's impossible 
									-- to start it at scheduled time
	max_run_time interval,	-- time interval - max execution time when 
							-- elapsed - sequence of queries will be aborted
	onrollback text,		-- statement to be executed on ROLLBACK
	max_instances int, 		-- the number of instances run at the same time
	next_time_statement text,	-- statement to be executed to calculate 
								-- next execution time
	active boolean,			-- job can be scheduled 
	broken boolean			-- if job is broken
);

CREATE TYPE cron_job AS(
	cron integer,			-- job record id
	node text,				-- node name 
	scheduled_at timestamp with time zone,	-- scheduled job time
	name text,				-- job name
	comments text,			-- job comments
	commands text[],		-- sql commands to execute
	run_as text,			-- name of the executor user
	owner text,				-- name of the owner user
	use_same_transaction boolean,	-- if true sequence of command executes
									-- in a single transaction
	started timestamp with time zone,		-- time when job started
	last_start_available timestamp with time zone,	-- time untill job must be started
	finished timestamp with time zone,		-- time when job finished
	max_run_time interval,	-- max execution time
	onrollback text,		-- statement on ROLLBACK
	next_time_statement text,	-- statement to calculate next start time
	max_instances int,		-- the number of instances run at the same time
	status job_status_t,	-- status of job
	message text			-- error message if one
);

----------------------------------
-- ADD Extension tables to Dump --
----------------------------------

select pg_extension_config_dump('at_jobs_submitted'::regclass, '');
select pg_extension_config_dump('at_jobs_submitted_id_seq'::regclass, '');
select pg_extension_config_dump('at_jobs_process'::regclass, '');
select pg_extension_config_dump('at_jobs_done'::regclass, '');
select pg_extension_config_dump('cron'::regclass, '');
select pg_extension_config_dump('cron_id_seq'::regclass, '');
select pg_extension_config_dump('at'::regclass, '');
select pg_extension_config_dump('log'::regclass, '');

----------
-- VIEW --
----------

--
-- show all scheduled jobs 
--
CREATE VIEW all_jobs_log AS 
	SELECT 
		coalesce(c.id, l.cron) as cron,
		c.node as node,
		l.start_at as scheduled_at,
		coalesce(c.name, '--DELETED--') as name,
		c.comments as comments,
		c.do_sql as commands,
		c.executor as run_as,
		c.owner as owner,
		c.same_transaction as use_same_transaction,
		l.started as started,
		l.last_start_available as last_start_available,
		l.finished as finished,
		c.max_run_time as max_run_time,
		c.onrollback_statement as onrollback,
		c.next_time_statement as next_time_statement,
		c.max_instances as max_instances,
		CASE WHEN l.status THEN
			'done'::@extschema@.job_status_t
		ELSE
			'error'::@extschema@.job_status_t
		END as status,
		l.message as message

	FROM @extschema@.log as l LEFT OUTER JOIN @extschema@.cron as c ON c.id = l.cron;

--
-- show scheduled jobs of session user
--

CREATE VIEW jobs_log AS 
	SELECT
		coalesce(c.id, l.cron) as cron,
		c.node as node,
		l.start_at as scheduled_at,
		coalesce(c.name, '--DELETED--') as name,
		c.comments as comments,
		c.do_sql as commands,
		c.executor as run_as,
		c.owner as owner,
		c.same_transaction as use_same_transaction,
		l.started as started,
		l.last_start_available as last_start_available,
		l.finished as finished,
		c.max_run_time as max_run_time,
		c.onrollback_statement as onrollback,
		c.next_time_statement as next_time_statement,
		c.max_instances as max_instances,
		CASE WHEN l.status THEN
			'done'::@extschema@.job_status_t
		ELSE
			'error'::@extschema@.job_status_t
		END as status,
		l.message as message
	FROM log as l, cron as c WHERE c.executor = session_user AND c.id = l.cron;

--
-- show parallel jobs of session_user
--

CREATE VIEW job_status AS 
	SELECT 
		id, node, name, comments, at as run_after,
		do_sql as query, params, depends_on, executor as run_as, attempt, 
		resubmit_limit, postpone as max_wait_interval,
		max_run_time as max_duration, submit_time, canceled,
		start_time, status as is_success, reason as error, done_time,
		'done'::@extschema@.job_at_status_t status
	FROM @extschema@.at_jobs_done where owner = session_user
		UNION 
	SELECT
		id, node, name, comments, at as run_after,
		do_sql as query, params, depends_on, executor as run_as, attempt, 
		resubmit_limit, postpone as max_wait_interval,
		max_run_time as max_duration, submit_time, canceled, start_time, 
		NULL as is_success, NULL as error, NULL as done_time,
		'processing'::@extschema@.job_at_status_t status
	FROM ONLY @extschema@.at_jobs_process where owner = session_user
		UNION
	SELECT
		id, node, name, comments, at as run_after,
		do_sql as query, params, depends_on, executor as run_as, attempt, 
		resubmit_limit, postpone as max_wait_interval,
		max_run_time as max_duration, submit_time, canceled, 
		NULL as start_time, NULL as is_success, NULL as error,
		NULL as done_time,
		'submitted'::@extschema@.job_at_status_t status
	FROM ONLY @extschema@.at_jobs_submitted where owner = session_user;

--
-- show all parallel jobs 
--

CREATE VIEW all_job_status AS 
	SELECT 
		id, node, name, comments, at as run_after,
		do_sql as query, params, depends_on, executor as run_as, owner,
		attempt, resubmit_limit, postpone as max_wait_interval,
		max_run_time as max_duration, submit_time, canceled,
		start_time, status as is_success, reason as error, done_time,
		'done'::@extschema@.job_at_status_t status
	FROM @extschema@.at_jobs_done 
		UNION 
	SELECT
		id, node, name, comments, at as run_after,
		do_sql as query, params, depends_on, executor as run_as, owner,
		attempt, resubmit_limit, postpone as max_wait_interval,
		max_run_time as max_duration, submit_time, canceled, start_time,
		NULL as is_success, NULL as error, NULL as done_time,
		'processing'::@extschema@.job_at_status_t status
	FROM ONLY @extschema@.at_jobs_process 
		UNION
	SELECT
		id, node, name, comments, at as run_after,
		do_sql as query, params, depends_on, executor as run_as, owner,
		attempt, resubmit_limit, postpone as max_wait_interval,
		max_run_time as max_duration, submit_time, canceled,
		NULL as start_time, NULL as is_success, NULL as error,
		NULL as done_time,
		'submitted'::@extschema@.job_at_status_t status
	FROM ONLY @extschema@.at_jobs_submitted;

---------------
-- FUNCTIONS --
---------------

------------------------------
-- -- AT EXECUTOR FUNCTIONS --
------------------------------

CREATE FUNCTION get_self_id()
  RETURNS bigint 
  AS 'MODULE_PATHNAME', 'get_self_id'
  LANGUAGE C IMMUTABLE;

CREATE FUNCTION resubmit(run_after interval default NULL)
  RETURNS bigint 
  AS 'MODULE_PATHNAME', 'resubmit'
  LANGUAGE C IMMUTABLE;

CREATE FUNCTION cancel_job(job_id bigint)  RETURNS boolean AS
$BODY$
DECLARE
	s_count int;
BEGIN
	EXECUTE 'SELECT count(*)  FROM at_jobs_submitted WHERE owner  = session_user AND id = $1' INTO s_count USING job_id;
	IF s_count > 0 THEN
		UPDATE at_jobs_submitted SET canceled = true WHERE "id" = job_id;
		WITH moved_rows AS (DELETE from ONLY at_jobs_submitted a WHERE a.id = job_id RETURNING a.*) INSERT INTO at_jobs_done SELECT *, NULL as start_time, false as status, 'job was canceled' as reason FROM moved_rows;
		RETURN true;
	ELSE
		EXECUTE 'SELECT count(*)  FROM at_jobs_process WHERE owner  = session_user AND id = $1' INTO s_count USING job_id;
		IF s_count > 0 THEN
			UPDATE at_jobs_process SET canceled = true WHERE "id" = job_id;
			RETURN true;
		END IF;
	END IF;

	RETURN false;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;


CREATE FUNCTION submit_job(
	query text,
	params text[] default NULL,
	run_after timestamp with time zone default NULL,
	node text default NULL,
	max_duration interval default NULL,
	max_wait_interval interval default NULL,
	run_as text default NULL,
	depends_on bigint[] default NULL,
	name text default NULL,
	comments text default NULL,
	resubmit_limit bigint default 100
) RETURNS bigint AS
$BODY$
DECLARE
	last_avail timestamp with time zone;
	executor text;
	rec record;
	job_id bigint;
BEGIN
	IF query IS NULL THEN
		RAISE EXCEPTION 'there is no ''query'' parameter';
	END IF;

	IF run_after IS NULL AND depends_on IS NULL THEN
		run_after := now();
	END IF;
	IF run_after IS NOT NULL AND depends_on IS NOT NULL THEN
		RAISE EXCEPTION 'conflict in start time'
			USING HINT = 'you cannot use ''run_after'' and ''depends_on'' parameters at the same time';
	END IF;

	IF max_wait_interval IS NOT NULL AND run_after IS NOT NULL THEN
		last_avail := run_after + max_wait_interval;
	ELSE
		last_avail := NULL;
	END IF;

	IF node IS NULL THEN
		node := 'master';
	END IF;

	IF run_as IS NOT NULL AND run_as <> session_user THEN
		executor := run_as;
		BEGIN
			SELECT * INTO STRICT rec FROM pg_roles WHERE rolname = executor;
			EXCEPTION
				WHEN NO_DATA_FOUND THEN
			RAISE EXCEPTION 'there is no such user %', executor;
			SET SESSION AUTHORIZATION executor; 
			RESET SESSION AUTHORIZATION;
		END;
	ELSE
		executor := session_user;
	END IF;

	INSERT INTO at_jobs_submitted
		(node, at, do_sql, owner, executor, name, comments, max_run_time,
		 postpone, last_start_available, depends_on, params,
		 attempt, resubmit_limit)
	VALUES
		(node, run_after, query, session_user, executor,  name, comments,
		 max_duration, max_wait_interval, last_avail, depends_on, params,
		 0, resubmit_limit)
	RETURNING id INTO job_id;

	RETURN job_id;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

------------------------------------
-- -- SHEDULER EXECUTOR FUNCTIONS --
------------------------------------

CREATE FUNCTION onlySuperUser() RETURNS boolean  AS
$BODY$
DECLARE
	is_superuser boolean;
BEGIN
	EXECUTE 'SELECT rolsuper FROM pg_roles WHERE rolname = session_user'
	INTO is_superuser;
		IF NOT is_superuser THEN
			RAISE EXCEPTION 'access denied';
	END IF;
	RETURN TRUE;
END
$BODY$  LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION on_cron_update() RETURNS TRIGGER
AS $BODY$
DECLARE
  cron_id INTEGER;
BEGIN
  cron_id := NEW.id; 
  IF NOT NEW.active OR NEW.broken OR
  	coalesce(NEW.rule <> OLD.rule, true) OR
	coalesce(NEW.postpone <> OLD.postpone, true)  OR
	coalesce(NEW.start_date <> OLD.start_date, true) OR
	coalesce(NEW.end_date <> OLD.end_date, true)
  THEN
     DELETE FROM at WHERE cron = cron_id AND active = false;
  END IF;
  RETURN OLD;
END
$BODY$  LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION on_cron_delete() RETURNS TRIGGER
AS $BODY$
DECLARE
  cron_id INTEGER;
BEGIN
  cron_id := OLD.id; 
  DELETE FROM at WHERE cron = cron_id;
  RETURN OLD;
END
$BODY$  LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION _is_job_editable(jobId integer) RETURNS boolean AS
$BODY$
DECLARE
   is_superuser boolean;
   job record;
BEGIN
   BEGIN
      SELECT * INTO STRICT job FROM cron WHERE id = jobId;
      EXCEPTION
         WHEN NO_DATA_FOUND THEN
	    RAISE EXCEPTION 'there is no such job with id %', jobId;
         WHEN TOO_MANY_ROWS THEN
	    RAISE EXCEPTION 'there are more than one job with id %', jobId;
   END;	
   EXECUTE 'SELECT rolsuper FROM pg_roles WHERE rolname = session_user'
      INTO is_superuser;
   IF is_superuser THEN
      RETURN true;
   END IF;
   IF job.owner = session_user THEN
      RETURN true;
   END IF;

   RETURN false;
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION _possible_args() RETURNS jsonb AS
$BODY$
BEGIN 
   RETURN jsonb_build_object(
      'node', 'node name (default: master)',
      'name', 'job name',
      'comments', 'some comments on job',
      'cron', 'cron string rule',
      'rule', 'jsonb job schedule',
      'command', 'sql command to execute',
      'commands', 'sql commands to execute, text[]',
      'run_as', 'user to execute command(s)',
      'start_date', 'begin of period while command could be executed, could be NULL',
      'end_date', 'end of period while command could be executed, could be NULL',
      'date', 'Exact date when command will be executed',
      'dates', 'Set of exact dates when comman will be executed',
      'use_same_transaction', 'if set of commans should be executed within the same transaction',
      'last_start_available', 'for how long could command execution be postponed in  format of interval type' ,
      'max_run_time', 'how long job could be executed, NULL - infinite',
      'max_instances', 'the number of instances run at the same time',
      'onrollback', 'statement to be executed after rollback if one occured',
      'next_time_statement', 'statement to be executed last to calc next execution time'
   );
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;


CREATE FUNCTION _get_excess_keys(params jsonb) RETURNS text[] AS
$BODY$
DECLARE
   excess text[];
   possible jsonb;
   key record;
BEGIN
   possible := _possible_args();

   FOR key IN SELECT * FROM  jsonb_object_keys(params) AS name LOOP
      IF NOT possible?key.name THEN
         EXECUTE 'SELECT array_append($1, $2)'
         INTO excess
         USING excess, key.name;
      END IF;
   END LOOP;

   RETURN excess;
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION _string_or_null(str text) RETURNS text AS
$BODY$
BEGIN
   IF lower(str) = 'null' OR str = '' THEN
      RETURN 'NULL';
   END IF;
   RETURN quote_literal(str);
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION _get_cron_from_attrs(params jsonb, prev jsonb) RETURNS jsonb AS
$BODY$
DECLARE
	dates text[];
	cron jsonb;
	rule jsonb;
	clean_cron jsonb;
	N integer;
	name text;
	updatePrev boolean;
BEGIN

	updatePrev := true;

	IF NOT params?'cron' AND NOT params?'rule' AND NOT params?'date' AND NOT params?'dates' THEN
		RAISE  EXCEPTION 'There is no information about job''s schedule'
			USING HINT = 'Use ''cron'' - cron string, ''rule'' - json to set schedule rules or ''date'' and ''dates'' to set exact date(s)';
	END IF;

	IF params?'cron' THEN 
		EXECUTE 'SELECT cron2jsontext($1::cstring)::jsonb' 
			INTO cron
			USING params->>'cron';
	END IF;

	IF params?'rule' THEN
		rule := params->'rule';
		updatePrev := false;
	END IF;

	cron := coalesce(cron, '{}'::jsonb) || coalesce(rule, '{}'::jsonb);

	IF cron?'date' THEN
		dates := _get_array_from_jsonb(dates, cron->'date');
	END IF;
	IF cron?'dates' THEN
		dates := _get_array_from_jsonb(dates, cron->'dates');
	END IF;

	IF params?'date' THEN
		dates := _get_array_from_jsonb(dates, params->'date');
	END IF;
	IF params?'dates' THEN
		dates := _get_array_from_jsonb(dates, params->'dates');
	END IF;
	N := array_length(dates, 1);
	
	IF N > 0 THEN
		EXECUTE 'SELECT array_agg(lll) FROM (SELECT distinct(date_trunc(''min'', unnest::timestamp with time zone)) as lll FROM unnest($1) ORDER BY date_trunc(''min'', unnest::timestamp with time zone)) as Z'
			INTO dates USING dates;
		cron := cron || jsonb_build_object('dates', array_to_json(dates));
	END IF;

	IF updatePrev AND prev IS NOT NULL THEN
		cron := prev || cron;
	END IF;

	clean_cron := '{}'::jsonb;
	FOR name IN SELECT * FROM unnest('{dates, crontab, onstart, days, hours, wdays, months, minutes}'::text[])
	LOOP
		IF cron?name THEN
			clean_cron := jsonb_set(clean_cron, array_append('{}'::text[], name), cron->name);
		END IF;
	END LOOP;
	RETURN clean_cron;
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION _get_array_from_jsonb(dst text[], src jsonb) RETURNS text[] AS
$BODY$
DECLARE
	vtype text;
BEGIN
	IF src IS NULL THEN
		RETURN dst;
	END IF;

	SELECT INTO vtype jsonb_typeof(src);

	IF vtype = 'string' THEN
		SELECT INTO dst array_append(dst, src->>0);
	ELSIF vtype = 'array' THEN
		SELECT INTO dst dst || array_agg(value)::text[] from jsonb_array_elements_text(src);
	ELSE
		RAISE EXCEPTION 'The value could be only ''string'' or ''array'' type';
	END IF;

	RETURN dst;
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION _get_commands_from_attrs(params jsonb) RETURNS text[] AS
$BODY$
DECLARE
	commands text[];
	N integer;
BEGIN
	N := 0;
	IF params?'command' THEN
		commands := _get_array_from_jsonb(commands, params->'command');
	END IF;

	IF params?'commands' THEN
		commands := _get_array_from_jsonb(commands, params->'commands');
	END IF;

	N := array_length(commands, 1);
	IF N is NULL or N = 0 THEN
		RAISE EXCEPTION 'There is no information about what job to execute'
			USING HINT = 'Use ''command'' or ''commands'' key to transmit information';
   END IF;

   RETURN commands;
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;


CREATE FUNCTION _get_executor_from_attrs(params jsonb) RETURNS text AS
$BODY$
DECLARE
   rec record;
   executor text;
BEGIN
   IF params?'run_as' AND  params->>'run_as' <> session_user THEN
      executor := params->>'run_as';
      BEGIN
         SELECT * INTO STRICT rec FROM pg_roles WHERE rolname = executor;
         EXCEPTION
            WHEN NO_DATA_FOUND THEN
	       RAISE EXCEPTION 'there is no such user %', executor;
         SET SESSION AUTHORIZATION executor; 
         RESET SESSION AUTHORIZATION;
      END;
   ELSE
      executor := session_user;
   END IF;

   RETURN executor;
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;
   

CREATE FUNCTION create_job(params jsonb) RETURNS integer AS
$BODY$
DECLARE 
   cron jsonb;
   commands text[];
   orb_statement text;
   start_date timestamp with time zone;
   end_date timestamp with time zone;
   executor text;
   owner text;
   max_run_time interval;
   excess text[];
   job_id integer;
   v_same_transaction boolean;
   v_next_time_statement text;
   v_postpone interval;
   v_onrollback text;
   name text;
   comments text;
   node text;
   mi int;
BEGIN
   EXECUTE 'SELECT _get_excess_keys($1)'
      INTO excess
      USING params;
   IF array_length(excess,1) > 0 THEN
      RAISE WARNING 'You used excess keys in params: %.', array_to_string(excess, ', ');
   END IF;

   cron := _get_cron_from_attrs(params, NULL);
   commands := _get_commands_from_attrs(params);
   executor := _get_executor_from_attrs(params);
   node := 'master';
   mi := 1;

   IF params?'start_date' THEN
      start_date := (params->>'start_date')::timestamp with time zone;
   END IF;

   IF params?'end_date' THEN
      end_date := (params->>'end_date')::timestamp with time zone;
   END IF;

   IF params?'name' THEN
      name := params->>'name';
   END IF;

   IF params?'comments' THEN
      name := params->>'comments';
   END IF;

   IF params?'max_run_time' THEN
      max_run_time := (params->>'max_run_time')::interval;
   END IF;

   IF params?'last_start_available' THEN
      v_postpone := (params->>'last_start_available')::interval;
   END IF;

   IF params?'use_same_transaction' THEN
      v_same_transaction := (params->>'use_same_transaction')::boolean;
   ELSE
      v_same_transaction := false;
   END IF;

   IF params?'onrollback' THEN
      v_onrollback := params->>'onrollback';
   END IF;

   IF params?'next_time_statement' THEN
      v_next_time_statement := params->>'next_time_statement';
   END IF;

   IF params?'node' AND params->>'node' IS NOT NULL THEN
      node := params->>'node';
   END IF;

   IF params?'max_instances' AND params->>'max_instances' IS NOT NULL AND (params->>'max_instances')::int > 1 THEN
      mi := (params->>'max_instances')::int;
   END IF;

   INSERT INTO cron
     (node, rule, do_sql, owner, executor,start_date, end_date, name, comments,
      max_run_time, same_transaction, active, onrollback_statement,
	  next_time_statement, postpone, max_instances)
     VALUES
     (node, cron, commands, session_user, executor, start_date, end_date, name,
      comments, max_run_time, v_same_transaction, true,
      v_onrollback, v_next_time_statement, v_postpone, mi)
     RETURNING id INTO job_id;

   RETURN job_id;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION create_job(cron text, command text, node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN create_job(jsonb_build_object('cron', cron, 'command', command, 'node', node));
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION create_job(dt timestamp with time zone, command text, node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN create_job(jsonb_build_object('date', dt::text, 'command', command, 'node', node));
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION create_job(dts timestamp with time zone[], command text, node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN create_job(jsonb_build_object('dates', array_to_json(dts), 'command', command, 'node', node));
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION create_job(cron text, commands text[], node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN create_job(jsonb_build_object('cron', cron, 'commands', array_to_json(commands), 'node', node));
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION create_job(dt timestamp with time zone, commands text[], node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN create_job(jsonb_build_object('date', dt::text, 'commands', array_to_json(commands), 'node', node));
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION create_job(dts timestamp with time zone[], commands text[], node text DEFAULT NULL) RETURNS integer AS
$BODY$
BEGIN
	RETURN create_job(jsonb_build_object('dates', array_to_json(dts), 'commands', array_to_json(commands), 'node', node));
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION set_job_attributes(jobId integer, attrs jsonb) RETURNS boolean AS
$BODY$
DECLARE
   job record;
   cmd text;
   excess text[];
BEGIN
   IF NOT _is_job_editable(jobId) THEN 
      RAISE EXCEPTION 'permission denied';
   END IF;
   EXECUTE 'SELECT _get_excess_keys($1)'
      INTO excess
      USING attrs;
   IF array_length(excess,1) > 0 THEN
      RAISE WARNING 'You used excess keys in params: %.', array_to_string(excess, ', ');
   END IF;

   EXECUTE 'SELECT * FROM cron WHERE id = $1'
      INTO job
      USING jobId;

   cmd := '';

   IF attrs?'cron' OR attrs?'date' OR attrs?'dates' OR attrs?'rule' THEN
      cmd := cmd || 'rule = ' ||
        quote_literal(_get_cron_from_attrs(attrs, job.rule)) || '::jsonb, ';
   END IF;

   IF attrs?'command' OR attrs?'commands' THEN
      cmd := cmd || 'do_sql = ' ||
        quote_literal(_get_commands_from_attrs(attrs)) || '::text[], ';
   END IF;

   IF attrs?'run_as' THEN
      cmd := cmd || 'executor = ' ||
        quote_literal(_get_executor_from_attrs(attrs)) || ', ';
   END IF;

   IF attrs?'start_date' THEN
      cmd := cmd || 'start_date = ' ||
        _string_or_null(attrs->>'start_date') || '::timestamp with time zone, ';
   END IF;

   IF attrs?'end_date' THEN
      cmd := cmd || 'end_date = ' ||
        _string_or_null(attrs->>'end_date') || '::timestamp with time zone, ';
   END IF;

   IF attrs?'name' THEN
      cmd := cmd || 'name = ' ||
        _string_or_null(attrs->>'name') || ', ';
   END IF;

   IF attrs?'node' THEN
      cmd := cmd || 'node = ' ||
        _string_or_null(attrs->>'node') || ', ';
   END IF;

   IF attrs?'comments' THEN
      cmd := cmd || 'comments = ' ||
        _string_or_null(attrs->>'comments') || ', ';
   END IF;

   IF attrs?'max_run_time' THEN
      cmd := cmd || 'max_run_time = ' ||
        _string_or_null(attrs->>'max_run_time') || '::interval, ';
   END IF;

   IF attrs?'onrollback' THEN
      cmd := cmd || 'onrollback_statement = ' ||
        _string_or_null(attrs->>'onrollback') || ', ';
   END IF;

   IF attrs?'next_time_statement' THEN
      cmd := cmd || 'next_time_statement = ' ||
        _string_or_null(attrs->>'next_time_statement') || ', ';
   END IF;

   IF attrs?'use_same_transaction' THEN
      cmd := cmd || 'same_transaction = ' ||
        quote_literal(attrs->>'use_same_transaction') || '::boolean, ';
   END IF;

   IF attrs?'last_start_available' THEN
      cmd := cmd || 'postpone = ' ||
        _string_or_null(attrs->>'last_start_available') || '::interval, ';
   END IF; 

   IF attrs?'max_instances' AND attrs->>'max_instances' IS NOT NULL AND (attrs->>'max_instances')::int > 0 THEN
      cmd := cmd || 'max_instances = ' || (attrs->>'max_instances')::int || ', ';
   END IF;


   IF length(cmd) > 0 THEN
      cmd := substring(cmd from 0 for length(cmd) - 1);
   ELSE
      RETURN false;
   END IF;

   cmd := 'UPDATE cron SET ' || cmd || ' where id = $1';

   EXECUTE cmd
     USING jobId;

   RETURN true; 
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION set_job_attribute(jobId integer, name text, value jsonb) RETURNS boolean AS
$BODY$
BEGIN
   IF name <> 'rule'  THEN
      RAISE EXCEPTION 'key % cannot have a jsonb value. Only "rule" allowed', name;
   END IF;

   RETURN set_job_attributes(jobId, jsonb_build_object(name, value));
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION set_job_attribute(jobId integer, name text, value anyarray) RETURNS boolean AS
$BODY$
BEGIN
   IF name <> 'dates' AND name <> 'commands' THEN
      RAISE EXCEPTION 'key % cannot have an array value. Only dates, commands allowed', name;
   END IF;

   RETURN set_job_attributes(jobId, jsonb_build_object(name, array_to_json(value)));
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION set_job_attribute(jobId integer, name text, value text) RETURNS boolean AS
$BODY$
DECLARE
   attrs jsonb;
BEGIN
   IF name = 'dates' OR name = 'commands' THEN
      attrs := jsonb_build_object(name, array_to_json(value::text[]));
   ELSIF name = 'rule' THEN
      attrs := jsonb_build_object('rule', value::jsonb);
   ELSE
      attrs := jsonb_build_object(name, value);
   END IF;
   RETURN set_job_attributes(jobId, attrs);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION drop_job(jobId integer) RETURNS boolean AS
$BODY$
BEGIN
   IF NOT _is_job_editable(jobId) THEN 
      RAISE EXCEPTION 'permission denied';
   END IF;

   DELETE FROM cron WHERE id = jobId;

   RETURN true;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION deactivate_job(jobId integer) RETURNS boolean AS
$BODY$
BEGIN
   IF NOT _is_job_editable(jobId) THEN 
      RAISE EXCEPTION 'permission denied';
   END IF;

   UPDATE cron SET active = false WHERE id = jobId;

   RETURN true;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION activate_job(jobId integer) RETURNS boolean AS
$BODY$
BEGIN
   IF NOT _is_job_editable(jobId) THEN 
      RAISE EXCEPTION 'Permission denied';
   END IF;

   UPDATE cron SET active = true WHERE id = jobId;

   RETURN true;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION _make_cron_job(ii cron) RETURNS cron_job AS
$BODY$
DECLARE
	oo cron_job;
BEGIN
	oo.cron := ii.id;

	RETURN oo;
END
$BODY$
LANGUAGE plpgsql
	SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION _make_cron_rec(ii cron) RETURNS cron_rec AS
$BODY$
DECLARE
	oo cron_rec;
BEGIN
	oo.id := ii.id;
	oo.name := ii.name;
	oo.node := ii.node;
	oo.comments := ii.comments;
	oo.rule := ii.rule;
	oo.commands := ii.do_sql;
	oo.run_as := ii.executor;
	oo.owner := ii.owner;
	oo.start_date := ii.start_date;
	oo.end_date := ii.end_date;
	oo.use_same_transaction := ii.same_transaction;
	oo.last_start_available := ii.postpone;
	oo.max_run_time := ii.max_run_time;
	oo.onrollback := ii.onrollback_statement;
	oo.next_time_statement := ii.next_time_statement;
	oo.max_instances := ii.max_instances;
	oo.active := ii.active;
	oo.broken := ii.broken;

	RETURN oo;
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;

CREATE FUNCTION clean_log() RETURNS INT  AS
$BODY$
DECLARE
	cnt integer;
BEGIN
    PERFORM onlySuperUser();

	WITH a AS (DELETE FROM log RETURNING 1)
		SELECT count(*) INTO cnt FROM a;

	RETURN cnt;
END
$BODY$
LANGUAGE plpgsql set search_path TO @extschema@;

create FUNCTION get_job(jobId int) RETURNS cron_rec AS
$BODY$
DECLARE
	job cron;
BEGIN
	IF NOT _is_job_editable(jobId) THEN 
		RAISE EXCEPTION 'permission denied';
	END IF;
	EXECUTE 'SELECT * FROM cron WHERE id = $1'
		INTO job
		USING jobId;
	RETURN _make_cron_rec(job);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_cron() RETURNS SETOF cron_rec AS
$BODY$
DECLARE
	ii cron;
	oo cron_rec;
BEGIN
    PERFORM onlySuperUser();

	FOR ii IN SELECT * FROM cron LOOP
		oo := _make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_owned_cron() RETURNS SETOF cron_rec AS
$BODY$
DECLARE
	ii cron;
	oo cron_rec;
BEGIN
	FOR ii IN SELECT * FROM cron WHERE owner = session_user LOOP
		oo := _make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;


CREATE FUNCTION get_owned_cron(usename text) RETURNS SETOF cron_rec AS
$BODY$
DECLARE
	ii cron;
	oo cron_rec;
BEGIN
	IF usename <> session_user THEN
    	PERFORM onlySuperUser();
	END IF;

	FOR ii IN SELECT * FROM cron WHERE owner = usename LOOP
		oo := _make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_user_owned_cron() RETURNS SETOF cron_rec AS
$BODY$
BEGIN
	RETURN QUERY  SELECT * from get_owned_cron();
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_user_owned_cron(usename text) RETURNS SETOF cron_rec AS
$BODY$
BEGIN
	RETURN QUERY SELECT * from  get_owned_cron(usename);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;



CREATE FUNCTION get_user_cron() RETURNS SETOF cron_rec AS
$BODY$
DECLARE
	ii cron;
	oo cron_rec;
BEGIN
	FOR ii IN SELECT * FROM cron WHERE executor = session_user LOOP
		oo := _make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_user_cron(usename text) RETURNS SETOF cron_rec AS
$BODY$
DECLARE
	ii cron;
	oo cron_rec;
BEGIN
	IF usename <> session_user THEN
    	PERFORM onlySuperUser();
	END IF;

	FOR ii IN SELECT * FROM cron WHERE executor = usename LOOP
		oo := _make_cron_rec(ii);
		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_user_active_jobs() RETURNS SETOF cron_job AS
$BODY$
DECLARE
	ii record;
	oo cron_job;
BEGIN
	FOR ii IN SELECT * FROM at as at, cron as cron WHERE cron.executor = session_user AND cron.id = at.cron AND at.active LOOP
		oo.cron = ii.id;
		oo.node = ii.node;
		oo.scheduled_at = ii.start_at;
		oo.name = ii.name;
		oo.comments= ii.comments;
		oo.commands = ii.do_sql;
		oo.run_as = ii.executor;
		oo.owner = ii.owner;
		oo.max_instances = ii.max_instances;
		oo.use_same_transaction = ii.same_transaction;
		oo.started = ii.started;
		oo.last_start_available = ii.last_start_available;
		oo.finished = NULL;
		oo.max_run_time = ii.max_run_time;
		oo.onrollback = ii.onrollback_statement;
		oo.next_time_statement = ii.next_time_statement;
		oo.message = NULL;
		oo.status = 'working';

		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_active_jobs(usename text) RETURNS SETOF cron_job AS
$BODY$
DECLARE
BEGIN
	RETURN QUERY  SELECT * FROM get_user_active_jobs(usename);
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_active_jobs() RETURNS SETOF cron_job AS
$BODY$
DECLARE
	ii record;
	oo cron_job;
BEGIN
    PERFORM onlySuperUser();
	FOR ii IN SELECT * FROM at as at, cron as cron WHERE cron.id = at.cron AND at.active LOOP
		oo.cron = ii.id;
		oo.node = ii.node;
		oo.scheduled_at = ii.start_at;
		oo.name = ii.name;
		oo.comments= ii.comments;
		oo.commands = ii.do_sql;
		oo.run_as = ii.executor;
		oo.owner = ii.owner;
		oo.max_instances = ii.max_instances;
		oo.use_same_transaction = ii.same_transaction;
		oo.started = ii.started;
		oo.last_start_available = ii.last_start_available;
		oo.finished = NULL;
		oo.max_run_time = ii.max_run_time;
		oo.onrollback = ii.onrollback_statement;
		oo.next_time_statement = ii.next_time_statement;
		oo.message = NULL;
		oo.status = 'working';

		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_user_active_jobs(usename text) RETURNS SETOF cron_job AS
$BODY$
DECLARE
	ii record;
	oo cron_job;
BEGIN
	IF usename <> session_user THEN
    	PERFORM onlySuperUser();
	END IF;

	FOR ii IN SELECT * FROM at, cron WHERE cron.executor = usename AND cron.id = at.cron AND at.active LOOP
		oo.cron = ii.id;
		oo.node = ii.node;
		oo.scheduled_at = ii.start_at;
		oo.name = ii.name;
		oo.comments= ii.comments;
		oo.commands = ii.do_sql;
		oo.run_as = ii.executor;
		oo.max_instances = ii.max_instances;
		oo.owner = ii.owner;
		oo.use_same_transaction = ii.same_transaction;
		oo.started = ii.started;
		oo.last_start_available = ii.last_start_available;
		oo.finished = NULL;
		oo.max_run_time = ii.max_run_time;
		oo.onrollback = ii.onrollback_statement;
		oo.next_time_statement = ii.next_time_statement;
		oo.message = NULL;
		oo.status = 'working';

		RETURN NEXT oo;
	END LOOP;
	RETURN;
END
$BODY$
LANGUAGE plpgsql
   SECURITY DEFINER set search_path TO @extschema@;

CREATE FUNCTION get_log(usename text) RETURNS 
	table(
		cron int,
		node text,
		scheduled_at timestamp with time zone,
		name text,
		comments text,
		commands text[],
		run_as text,
		owner text,
		use_same_transaction boolean,
		started timestamp with time zone,
		last_start_available timestamp with time zone,
		finished timestamp with time zone,
		max_run_time interval,
		onrollback text,
		next_time_statement text,
		max_instances integer,
		status @extschema@.job_status_t,
		message text
	)
AS
$BODY$
 	SELECT * FROM @extschema@.all_jobs_log where owner = usename;
$BODY$
LANGUAGE sql STABLE; 



CREATE FUNCTION get_log() RETURNS 
	table(
		cron int,
		node text,
		scheduled_at timestamp with time zone,
		name text,
		comments text,
		commands text[],
		run_as text,
		owner text,
		use_same_transaction boolean,
		started timestamp with time zone,
		last_start_available timestamp with time zone,
		finished timestamp with time zone,
		max_run_time interval,
		onrollback text,
		next_time_statement text,
		max_instances integer,
		status @extschema@.job_status_t,
		message text
	)
AS
$BODY$
 	SELECT * FROM @extschema@.all_jobs_log;
$BODY$
LANGUAGE sql STABLE; 


CREATE FUNCTION get_user_log() RETURNS 
	table(
		cron int,
		node text,
		scheduled_at timestamp with time zone,
		name text,
		comments text,
		commands text[],
		run_as text,
		owner text,
		use_same_transaction boolean,
		started timestamp with time zone,
		last_start_available timestamp with time zone,
		finished timestamp with time zone,
		max_run_time interval,
		onrollback text,
		next_time_statement text,
		max_instances integer,
		status @extschema@.job_status_t,
		message text
	)
AS
$BODY$
 	SELECT * FROM @extschema@.jobs_log;
$BODY$
LANGUAGE sql STABLE; 

CREATE FUNCTION cron2jsontext(CSTRING)
  RETURNS text 
  AS 'MODULE_PATHNAME', 'cron_string_to_json_text'
  LANGUAGE C IMMUTABLE;

--------------
-- TRIGGERS --
--------------

CREATE TRIGGER cron_delete_trigger 
BEFORE DELETE ON cron 
   FOR EACH ROW EXECUTE PROCEDURE on_cron_delete();

CREATE TRIGGER cron_update_trigger 
AFTER UPDATE ON cron 
   FOR EACH ROW EXECUTE PROCEDURE on_cron_update();
 
-----------
-- GRANT --
-----------

GRANT USAGE ON SCHEMA @extschema@ TO public;
GRANT SELECT ON @extschema@.job_status TO public;
GRANT SELECT ON @extschema@.jobs_log TO public;

