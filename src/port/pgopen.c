/*-------------------------------------------------------------------------
 *
 * pgopen.c
 *	  open() with retry on EINTR
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/port/pgopen.c
 *
 *-------------------------------------------------------------------------
 */

#if !defined(WIN32) || defined(__CYGWIN__)

#ifndef FRONTEND
#include "postgres.h"
#else
#include "postgres_fe.h"
#endif

#include <fcntl.h>

int
pg_open(const char *path, int flags, mode_t mode)
{
	int			fd;

	do
		fd = open(path, flags, mode);
	while (fd < 0 && errno == EINTR);

	return fd;
}

#endif							/* !WIN32 || __CYGWIN__ */
