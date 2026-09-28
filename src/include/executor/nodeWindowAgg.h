/*-------------------------------------------------------------------------
 *
 * nodeWindowAgg.h
 *	  prototypes for nodeWindowAgg.c
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/executor/nodeWindowAgg.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef NODEWINDOWAGG_H
#define NODEWINDOWAGG_H

#include "nodes/execnodes.h"

extern WindowAggState *ExecInitWindowAgg(WindowAgg *node, EState *estate, int eflags);
extern void ExecEndWindowAgg(WindowAggState *node);
extern void ExecReScanWindowAgg(WindowAggState *node);

/* 표현식 평가 opcode를 위한 RPR 내비게이션 지원 */
extern TupleTableSlot *ExecRPRNavGetSlot(WindowAggState *winstate, int64 pos);

#endif							/* NODEWINDOWAGG_H */
