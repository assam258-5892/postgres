/*-------------------------------------------------------------------------
 *
 * parse_rpr.h
 *	  파서에서 행 패턴 인식(Row Pattern Recognition)을 처리한다
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/parser/parse_rpr.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef PARSE_RPR_H
#define PARSE_RPR_H

#include "parser/parse_node.h"

extern void transformRPR(ParseState *pstate, WindowClause *wc,
						 WindowDef *windef);

#endif							/* PARSE_RPR_H */
