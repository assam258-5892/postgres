/*-------------------------------------------------------------------------
 *
 * pgopen.c
 *	  Retry open() and the libc calls that open files on EINTR, for macOS
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

#ifndef FRONTEND
#include "postgres.h"
#else
#include "postgres_fe.h"
#endif

#include <fcntl.h>
#include <unistd.h>

#ifdef __darwin__

/*
 * open() is a system call and sets errno whenever it fails.  fopen(),
 * opendir() and getcwd() open inside libc, so clear errno before each try
 * lest a stale EINTR from some earlier call keep us looping when they fail
 * without setting it.  pg_freopen() opens with pg_open() and has no loop of
 * its own.
 */

int
pg_open(const char *path, int flags, mode_t mode)
{
	int			fd;

	do
		fd = open(path, flags, mode);
	while (fd < 0 && errno == EINTR);

	return fd;
}

FILE *
pg_fopen(const char *path, const char *mode)
{
	FILE	   *file;

	do
	{
		errno = 0;
		file = fopen(path, mode);
	} while (file == NULL && errno == EINTR);

	return file;
}

DIR *
pg_opendir(const char *path)
{
	DIR		   *dir;

	do
	{
		errno = 0;
		dir = opendir(path);
	} while (dir == NULL && errno == EINTR);

	return dir;
}

char *
pg_getcwd(char *buf, size_t size)
{
	char	   *cwd;

	do
	{
		errno = 0;
		cwd = getcwd(buf, size);
	} while (cwd == NULL && errno == EINTR);

	return cwd;
}

/*
 * freopen() closes the stream before it opens the file, so once that open has
 * failed there is no stream left to retry on.  Open the file first, with
 * pg_open(), and only then move it under the stream's descriptor; freopen()
 * with a null path then sets the stream's mode without opening anything.  If
 * the file cannot be opened, the stream is left as it was.
 */
FILE *
pg_freopen(const char *path, const char *mode, FILE *stream)
{
	int			flags;
	int			fd;
	int			target = fileno(stream);

	switch (mode[0])
	{
		case 'r':
			flags = O_RDONLY;
			break;
		case 'w':
			flags = O_WRONLY | O_CREAT | O_TRUNC;
			break;
		case 'a':
			flags = O_WRONLY | O_CREAT | O_APPEND;
			break;
		default:
			errno = EINVAL;
			return NULL;
	}
	if (strchr(mode, '+'))
		flags = (flags & ~O_ACCMODE) | O_RDWR;
	if (strchr(mode, 'x'))
		flags |= O_EXCL;

	if (target < 0)
	{
		errno = EBADF;
		return NULL;
	}

	fd = pg_open(path, flags, 0666);
	if (fd < 0)
		return NULL;

	fflush(stream);
	if (fd != target)
	{
		if (dup2(fd, target) < 0)
		{
			int			save_errno = errno;

			close(fd);
			errno = save_errno;
			return NULL;
		}
		close(fd);
	}

	return freopen(NULL, mode, stream);
}

#endif							/* __darwin__ */
