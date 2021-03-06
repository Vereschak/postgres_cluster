#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "postmaster/postmaster.h"
#include "postmaster/bgworker.h"
#include "storage/s_lock.h"
#include "storage/spin.h"
#include "storage/pg_sema.h"
#include "storage/shmem.h"

#include "bgwpool.h"

typedef struct
{
    BgwPoolConstructor constructor;
    int id;
} BgwPoolExecutorCtx;

size_t n_snapshots;
size_t n_active;

static void BgwPoolMainLoop(Datum arg)
{
    BgwPoolExecutorCtx* ctx = (BgwPoolExecutorCtx*)arg;
    int id = ctx->id;
    BgwPool* pool = ctx->constructor();
    int size;
    void* work;

    BackgroundWorkerUnblockSignals();
	BackgroundWorkerInitializeConnection(pool->dbname, NULL);

    elog(WARNING, "Start background worker %d", id);

    while(true) { 
        PGSemaphoreLock(&pool->available);
        SpinLockAcquire(&pool->lock);
        size = *(int*)&pool->queue[pool->head];
        Assert(size < pool->size);
        work = palloc(size);
        pool->active -= 1;
        if (pool->head + size + 4 > pool->size) { 
            memcpy(work, pool->queue, size);
            pool->head = INTALIGN(size);
        } else { 
            memcpy(work, &pool->queue[pool->head+4], size);
            pool->head += 4 + INTALIGN(size);
        }
        if (pool->size == pool->head) { 
            pool->head = 0;
        }
        if (pool->producerBlocked) {
            pool->producerBlocked = false;
            PGSemaphoreUnlock(&pool->overflow);
        }
        SpinLockRelease(&pool->lock);
        pool->executor(id, work, size);
        pfree(work);
    }
}

void BgwPoolInit(BgwPool* pool, BgwPoolExecutor executor, char const* dbname, size_t queueSize)
{
    pool->queue = (char*)ShmemAlloc(queueSize);
    pool->executor = executor;
    PGSemaphoreCreate(&pool->available);
    PGSemaphoreCreate(&pool->overflow);
    PGSemaphoreReset(&pool->available);
    PGSemaphoreReset(&pool->overflow);
    SpinLockInit(&pool->lock);
    pool->producerBlocked = false;
    pool->head = 0;
    pool->tail = 0;
    pool->size = queueSize;
    pool->active = 0;
    strcpy(pool->dbname, dbname);
}

void BgwPoolStart(int nWorkers, BgwPoolConstructor constructor)
{
    int i;
	BackgroundWorker worker;

	MemSet(&worker, 0, sizeof(BackgroundWorker));
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS |  BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_ConsistentState;
	worker.bgw_main = BgwPoolMainLoop;
	worker.bgw_restart_time = 10; /* Wait 10 seconds for restart before crash */
    
    for (i = 0; i < nWorkers; i++) { 
        BgwPoolExecutorCtx* ctx = (BgwPoolExecutorCtx*)malloc(sizeof(BgwPoolExecutorCtx));
        snprintf(worker.bgw_name, BGW_MAXLEN, "bgw_pool_worker_%d", i+1);
        ctx->id = i;
        ctx->constructor = constructor;
        worker.bgw_main_arg = (Datum)ctx;
        RegisterBackgroundWorker(&worker);
    }
}

void BgwPoolExecute(BgwPool* pool, void* work, size_t size)
{
    Assert(size+4 <= pool->size);
 
    SpinLockAcquire(&pool->lock);
    while (true) { 
        if ((pool->head <= pool->tail && pool->size - pool->tail < size + 4 && pool->head < size) 
            || (pool->head > pool->tail && pool->head - pool->tail < size + 4))
        {
            pool->producerBlocked = true;
            SpinLockRelease(&pool->lock);
            PGSemaphoreLock(&pool->overflow);
            SpinLockAcquire(&pool->lock);
        } else {
            pool->active += 1;
            n_snapshots += 1;
            n_active += pool->active;
            *(int*)&pool->queue[pool->tail] = size;
            if (pool->size - pool->tail >= size + 4) { 
                memcpy(&pool->queue[pool->tail+4], work, size);
                pool->tail += 4 + INTALIGN(size);
            } else { 
                memcpy(pool->queue, work, size);
                pool->tail = INTALIGN(size);
            }
            if (pool->tail == pool->size) {
                pool->tail = 0;
            }
            PGSemaphoreUnlock(&pool->available);
            break;
        }
    }
    SpinLockRelease(&pool->lock);            
}

