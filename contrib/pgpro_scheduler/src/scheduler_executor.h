#ifndef PGPRO_SCHEDULER_EXECUTOR_H
#define PGPRO_SCHEDULER_EXECUTOR_H

#include <stdarg.h>
#include "postgres.h"
#include "pgpro_scheduler.h"
#include "utils/timestamp.h"
#include "scheduler_job.h"

typedef enum {
	SchdExecutorInit,
	SchdExecutorWork,
	SchdExecutorDone,
	SchdExecutorResubmit,
	SchdExecutorError,
	SchdExecutorLimitReached,
	SchdExecutorIdling
} schd_executor_status_t;

typedef struct {
	bool new_job;

	char database[PGPRO_SCHEDULER_DBNAME_MAX];
	char nodename[PGPRO_SCHEDULER_NODENAME_MAX];
	char user[NAMEDATALEN];

	int cron_id;
	task_type_t type;
	TimestampTz start_at;

	schd_executor_status_t status;
	TimestampTz status_set;

	char message[PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX];

	TimestampTz next_time;

	bool set_invalid;
	char set_invalid_reason[PGPRO_SCHEDULER_EXECUTOR_MESSAGE_MAX];

	bool worker_exit;
} schd_executor_share_t;

typedef struct {
	char database[PGPRO_SCHEDULER_DBNAME_MAX];
	char nodename[PGPRO_SCHEDULER_NODENAME_MAX];
	TimestampTz start_at;

	schd_executor_status_t status;

	bool stop_worker;
} schd_executor_share_state_t;

typedef struct {
	int n;
	char **errors;
} executor_error_t;

extern PGDLLEXPORT void executor_worker_main(Datum arg);
job_t *initializeExecutorJob(schd_executor_share_t *data);
void set_shared_message(schd_executor_share_t *shared, executor_error_t *ee);
TimestampTz get_next_excution_time(char *sql, executor_error_t *ee);
int executor_onrollback(MemoryContext mem, job_t *job, executor_error_t *ee);
void set_pg_var(bool resulti, executor_error_t *ee);
int push_executor_error(executor_error_t *e, char *fmt, ...)  pg_attribute_printf(2, 3);
int set_session_authorization(char *username, char **error);
int do_one_job(schd_executor_share_t *shared, schd_executor_status_t *status);
int read_worker_job_limit(void);
void at_executor_worker_main(Datum arg);
int process_one_job(schd_executor_share_state_t *shared, schd_executor_status_t *status);
Oid set_session_authorization_by_name(char *rolename, char **error);

extern Datum get_self_id(PG_FUNCTION_ARGS);
extern Datum resubmit(PG_FUNCTION_ARGS);


#endif

