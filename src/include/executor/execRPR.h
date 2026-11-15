/*-------------------------------------------------------------------------
 *
 * execRPR.h
 *	  execRPR.c의 프로토타입 (NFA 기반 행 패턴 인식(RPR) 엔진)
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/executor/execRPR.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef EXECRPR_H
#define EXECRPR_H

#include "nodes/execnodes.h"

/* NFA 컨텍스트 관리 */
extern RPRNFAContext *ExecRPRStartContext(WindowAggState *winstate,
										  int64 startPos);
extern void ExecRPRFreeContext(WindowAggState *winstate, RPRNFAContext *ctx);

/* NFA 처리 */
extern void ExecRPRProcessRow(WindowAggState *winstate, int64 currentPos);
extern void ExecRPRCleanupDeadContexts(WindowAggState *winstate,
									   RPRNFAContext *excludeCtx);
extern void ExecRPRFinalizeAllContexts(WindowAggState *winstate, int64 lastPos);

/* NFA 통계 */
extern void ExecRPRRecordContextSuccess(WindowAggState *winstate,
										int64 matchLen);
extern void ExecRPRRecordContextFailure(WindowAggState *winstate,
										int64 failedLen);

#endif							/* EXECRPR_H */
