#ifdef __cplusplus
extern "C" {
#endif

#define PERL_NO_GET_CONTEXT /* we want efficiency */
#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>
#include <poll.h>
#include <perlio.h>

#ifdef __cplusplus
} /* extern "C" */
#endif

#define NEED_newSVpvn_flags
#include "ppport.h"

#include <sys/uio.h>
#include <errno.h>
#include <limits.h>

#include <sys/types.h>
#define _GNU_SOURCE             /* See feature_test_macros(7) */
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include "picohttpparser/picohttpparser.c"

#ifndef STATIC_INLINE /* a public perl API from 5.13.4 */
#   if defined(__GNUC__) || defined(__cplusplus) || (defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 199901L))
#       define STATIC_INLINE static inline
#   else
#       define STATIC_INLINE static
#   endif
#endif /* STATIC_INLINE */

#ifndef IOV_MAX
#  ifdef UIO_MAXIOV
#    define IOV_MAX UIO_MAXIOV
#  endif
#endif

#ifndef IOV_MAX
#  error "Unable to determine IOV_MAX from system headers"
#endif

#define MAX_HEADER_SIZE 16384
#define MAX_HEADER_NAME_LEN 1024
#define MAX_HEADERS         128
#define BAD_REQUEST "HTTP/1.0 400 Bad Request\r\nConnection: close\r\n\r\n400 Bad Request\r\n"

#define TOU(ch) (('a' <= ch && ch <= 'z') ? ch - ('a' - 'A') : ch)

static HV *env_template;

/* stolen from HTTP::Parser::XS */
static
size_t find_ch(const char* s, size_t len, char ch)
{
  size_t i;
  for (i = 0; i != len; ++i, ++s)
    if (*s == ch)
      break;
  return i;
}

static
int header_is(const struct phr_header* header, const char* name,
                    size_t len)
{
  const char* x, * y;
  if (header->name_len != len)
    return 0;
  for (x = header->name, y = name; len != 0; --len, ++x, ++y)
    if (TOU(*x) != *y)
      return 0;
  return 1;
}


STATIC_INLINE
void
store_path_info(pTHX_ HV* env, const char* src, size_t src_len) {
  size_t dlen = 0, i = 0;
  char *d;
  char s2, s3;
  SV * dst;

  dst = newSV(0);
  (void)SvUPGRADE(dst, SVt_PV);
  d = SvGROW(dst, src_len * 3 + 1);

  for (i = 0; i < src_len; i++ ) {
    if ( src[i] == '%' && isxdigit(src[i+1]) && isxdigit(src[i+2]) ) {
      s2 = src[i+1];
      s3 = src[i+2];
      s2 -= s2 <= '9' ? '0'
          : s2 <= 'F' ? 'A' - 10
          : 'a' - 10;
      s3 -= s3 <= '9' ? '0'
          : s3 <= 'F' ? 'A' - 10
          : 'a' - 10;
       d[dlen++] = s2 * 16 + s3;
       i += 2;
    }
    else {
      d[dlen++] = src[i];
    }
  }

  SvCUR_set(dst, dlen);
  SvPOK_only(dst);
  (void)hv_stores(env, "PATH_INFO", dst);
}


STATIC_INLINE
int
_parse_http_request(pTHX_ char *buf, ssize_t buf_len, HV *env) {
  const char* method;
  size_t method_len;
  const char* path;
  size_t path_len;
  int minor_version;
  struct phr_header headers[MAX_HEADERS];
  size_t num_headers = MAX_HEADERS;
  size_t question_at;
  size_t i;
  int ret;
  SV* last_value;
  char tmp[MAX_HEADER_NAME_LEN + sizeof("HTTP_") - 1];

  ret = phr_parse_request(
    buf, buf_len,
    &method, &method_len,
    &path, &path_len,
    &minor_version, headers, &num_headers, 0
  );

  if (ret < 0)
    goto done;

  (void)hv_stores(env, "REQUEST_METHOD", newSVpvn(method, method_len));
  (void)hv_stores(env, "REQUEST_URI", newSVpvn(path, path_len));
  (void)hv_stores(env, "SCRIPT_NAME", newSVpvn("", 0));
  (void)hv_stores(env, "SERVER_PROTOCOL", newSVpvf("HTTP/1.%d", minor_version));

  /* PATH_INFO QUERY_STRING */
  path_len = find_ch(path, path_len, '#'); /* strip off all text after # after storing request_uri */
  question_at = find_ch(path, path_len, '?');
  store_path_info(aTHX_ env, path, question_at);
  if (question_at != path_len) ++question_at;
  (void)hv_stores(env, "QUERY_STRING", newSVpvn(path + question_at, path_len - question_at));

  last_value = NULL;
  for (i = 0; i < num_headers; ++i) {
    if (headers[i].name != NULL) {
      const char* name;
      size_t name_len;
      SV** slot;
      if (header_is(headers + i, "CONTENT-TYPE", sizeof("CONTENT-TYPE") - 1)) {
        name = "CONTENT_TYPE";
        name_len = sizeof("CONTENT_TYPE") - 1;
      } else if (header_is(headers + i, "CONTENT-LENGTH", sizeof("CONTENT-LENGTH") - 1)) {
        name = "CONTENT_LENGTH";
        name_len = sizeof("CONTENT_LENGTH") - 1;
      } else {
        const char* s;
        char* d;
        size_t n;
        if (sizeof(tmp) - 5 < headers[i].name_len) {
          hv_clear(env);
          ret = -1;
          goto done;
        }
        strcpy(tmp, "HTTP_");
        for (s = headers[i].name, n = headers[i].name_len, d = tmp + 5;
          n != 0;
          s++, --n, d++) {
            *d = *s == '-' ? '_' : TOU(*s);
            name = tmp;
            name_len = headers[i].name_len + 5;
        }
      }
      slot = hv_fetch(env, name, name_len, 1);
      if ( !slot ) croak("failed to create hash entry");
      if (SvOK(*slot)) {
        sv_catpvn(*slot, ", ", 2);
        sv_catpvn(*slot, headers[i].value, headers[i].value_len);
      } else {
        sv_setpvn(*slot, headers[i].value, headers[i].value_len);
        last_value = *slot;
      }
    } else {
      /* continuing lines of a mulitiline header */
      sv_catpvn(last_value, headers[i].value, headers[i].value_len);
    }
  }
 done:
  return ret;
}


STATIC_INLINE
char *
svpv2char(SV *sv, STRLEN *lp)
{
  if (SvGAMAGIC(sv))
    sv = sv_2mortal(newSVsv(sv));
  return SvPV(sv, *lp);
}


STATIC_INLINE
int
_accept(int fileno, struct sockaddr *addr, socklen_t *addrlen) {
    int fd;
#ifdef SOCK_NONBLOCK
    fd = accept4(fileno, addr, addrlen, SOCK_CLOEXEC|SOCK_NONBLOCK);
#else
    fd = accept(fileno, addr, addrlen);
#endif
    if (fd < 0) {
      return fd;
    }
#ifndef SOCK_NONBLOCK
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
#endif
    return fd;
}



STATIC_INLINE
ssize_t
_writev_timeout(const int fileno, const double timeout, struct iovec *iovec, const int iovcnt ) {
    int rv;
    int nfound;
    struct pollfd wfds[1];
  DO_WRITE:
    rv = writev(fileno, iovec, iovcnt);
    if ( rv >= 0 ) {
      return rv;
    }
    if ( rv < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK ) {
      return rv;
    }
  WAIT_WRITE:
    while (1) {
      wfds[0].fd = fileno;
      wfds[0].events = POLLOUT;
      nfound = poll(wfds, 1, (int)timeout*1000);
      if ( nfound == 1 ) {
        break;
      }
      if ( nfound == 0 && errno != EINTR ) {
        return -1;
      }
    }
    goto DO_WRITE;
}

STATIC_INLINE
ssize_t
_read_timeout(const int fileno, const double timeout, char * read_buf, const int read_len ) {
    int rv;
    int nfound;
    struct pollfd rfds[1];
  DO_READ:
    rfds[0].fd = fileno;
    rfds[0].events = POLLIN;
    rv = read(fileno, read_buf, read_len);
    if ( rv >= 0 ) {
      return rv;
    }
    if ( rv < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK ) {
      return rv;
    }
  WAIT_READ:
    while (1) {
      nfound = poll(rfds, 1, (int)timeout*1000);
      if ( nfound == 1 ) {
        break;
      }
      if ( nfound == 0 && errno != EINTR ) {
        return -1;
      }
    }
    goto DO_READ;
}

STATIC_INLINE
ssize_t
_write_timeout(const int fileno, const double timeout, char * write_buf, const int write_len ) {
    int rv;
    int nfound;
    struct pollfd wfds[1];
  DO_WRITE:
    rv = write(fileno, write_buf, write_len);
    if ( rv >= 0 ) {
      return rv;
    }
    if ( rv < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK ) {
      return rv;
    }
  WAIT_WRITE:
    while (1) {
      wfds[0].fd = fileno;
      wfds[0].events = POLLOUT;
      nfound = poll(wfds, 1, (int)timeout*1000);
      if ( nfound == 1 ) {
        break;
      }
      if ( nfound == 0 && errno != EINTR ) {
        return -1;
      }
    }
    goto DO_WRITE;
}


MODULE = Plack::Handler::Chobi    PACKAGE = Plack::Handler::Chobi

PROTOTYPES: DISABLE

BOOT:
{
    AV * psgi_version;
    psgi_version = newAV();
    av_extend(psgi_version, 2);
    (void)av_push(psgi_version,newSViv(1));
    (void)av_push(psgi_version,newSViv(1));
    SvREADONLY_on((SV*)psgi_version);

    HV *e;
    e = newHV();
    (void)hv_stores(e,"SCRIPT_NAME",          newSVpvs(""));
    (void)hv_stores(e,"psgi.version",         newRV((SV*)psgi_version));
    (void)hv_stores(e,"psgi.errors",          newRV((SV*)PL_stderrgv));
    (void)hv_stores(e,"psgi.url_scheme",      newSVpvs("http"));
    (void)hv_stores(e,"psgi.run_once",        newSV(0));
    (void)hv_stores(e,"psgi.multithread",     newSV(0));
    (void)hv_stores(e,"psgi.multiprocess",    newSViv(1));
    (void)hv_stores(e,"psgi.streaming",       newSViv(1));
    (void)hv_stores(e,"psgi.nonblocking",     newSV(0));
    (void)hv_stores(e,"psgix.input.buffered", newSViv(1));
    (void)hv_stores(e,"psgix.harakiri",       newSViv(1));
 
    /* stolenn from Feersum */
    /* placeholders that get defined for every request */
    (void)hv_stores(e, "SERVER_PROTOCOL", &PL_sv_undef);
    (void)hv_stores(e, "SERVER_NAME",     &PL_sv_undef);
    (void)hv_stores(e, "SERVER_PORT",     &PL_sv_undef);
    (void)hv_stores(e, "REQUEST_URI",     &PL_sv_undef);
    (void)hv_stores(e, "REQUEST_METHOD",  &PL_sv_undef);
    (void)hv_stores(e, "PATH_INFO",       &PL_sv_undef);
    (void)hv_stores(e, "REMOTE_ADDR",     &PL_sv_placeholder);
    (void)hv_stores(e, "REMOTE_PORT",     &PL_sv_placeholder);

    /* defaults that get changed for some requests */
    (void)hv_stores(e, "psgi.input",      &PL_sv_placeholder);
    (void)hv_stores(e, "CONTENT_LENGTH",  &PL_sv_placeholder);
    (void)hv_stores(e, "QUERY_STRING",    &PL_sv_placeholder);

    /* anticipated headers */
    (void)hv_stores(e, "CONTENT_TYPE",           &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_HOST",              &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_USER_AGENT",        &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_ACCEPT",            &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_ACCEPT_LANGUAGE",   &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_ACCEPT_CHARSET",    &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_REFERER",           &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_COOKIE",            &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_IF_MODIFIED_SINCE", &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_IF_NONE_MATCH",     &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_IF_MODIFIED_SINCE", &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_IF_NONE_MATCH",     &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_CACHE_CONTROL",     &PL_sv_placeholder);
    (void)hv_stores(e, "HTTP_X_FORWARDED_FOR",   &PL_sv_placeholder);

    env_template = e;
}

SV *
accept_psgi(fileno, timeout, tcp, host, port)
    int fileno
    double timeout
    int tcp
    SV * host
    SV * port
PREINIT:
    int fd;
    struct sockaddr_in cliaddr;
    socklen_t len = sizeof(cliaddr);
    char read_buf[MAX_HEADER_SIZE];
    HV * env;
    int flag = 1;
    ssize_t rv = 0;
    ssize_t buf_len;
    ssize_t reqlen;
PPCODE:
{
    /* if ( my ($conn, $buf, $env) = accept_buffer(fileno($server),timeout,tcp,host,port) */

    fd = _accept(fileno, (struct sockaddr *)&cliaddr, &len);
    /* endif */
    if (fd < 0) {
      goto badexit;
    }

    rv = _read_timeout(fd, timeout, &read_buf[0], MAX_HEADER_SIZE);
    // printf("fd:%d rv:%ld %f %d\n",fd,rv,timeout);
    if ( rv <= 0 ) {
      close(fd);
      goto badexit;
    }

    env = newHVhv(env_template);

    if ( tcp == 1 ) {
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (char*)&flag, sizeof(int));
      (void)hv_stores(env,"REMOTE_ADDR",newSVpv(inet_ntoa(cliaddr.sin_addr),0));
      (void)hv_stores(env,"REMOTE_PORT",newSViv(cliaddr.sin_port));
    }
    else {
      (void)hv_stores(env,"REMOTE_ADDR",newSV(0));
      (void)hv_stores(env,"REMOTE_PORT",newSViv(0));
    }
    (void)hv_stores(env,"SERVER_PORT",SvREFCNT_inc(port));
    (void)hv_stores(env,"SERVER_NAME",SvREFCNT_inc(host));

    buf_len = rv;
    while (1) {
      reqlen = _parse_http_request(aTHX_ &read_buf[0],buf_len,env);
      if ( reqlen >= 0 ) {
        break;
      }
      else if ( reqlen == -1 ) {
        /* error */
        close(fd);
        goto badexit_clear;
      }
      if ( MAX_HEADER_SIZE - buf_len == 0 ) {
        /* too large header  */
       char* badreq;
       badreq = BAD_REQUEST;
       rv = _write_timeout(fd, timeout, badreq, sizeof(BAD_REQUEST) - 1);
       close(fd);
       goto badexit_clear;
      }
      /* request is incomplete */
      rv = _read_timeout(fd, timeout, &read_buf[buf_len], MAX_HEADER_SIZE - buf_len);
      if ( rv <= 0 ) {
        close(fd);
        goto badexit_clear;
      }
      buf_len += rv;
    }

    PUSHs(sv_2mortal(newSViv(fd)));
    PUSHs(sv_2mortal(newSVpvn(&read_buf[reqlen], buf_len - reqlen)));
    PUSHs(sv_2mortal(newRV_noinc((SV*)env)));
    XSRETURN(3);

    badexit_clear:
    sv_2mortal((SV*)env);
    badexit:
    XSRETURN(0);
}

unsigned long
read_timeout(fileno, rbuf, len, offset, timeout)
    int fileno
    SV * rbuf
    ssize_t len
    ssize_t offset
    double timeout
  PREINIT:
    SV * buf;
    char * d;
    ssize_t rv;
    ssize_t buf_len;
  CODE:
    if (!SvROK(rbuf)) croak("buf must be RV");
    buf = SvRV(rbuf);
    if (!SvOK(buf)) {
      sv_setpvn(buf,"",0);
    }
    SvUPGRADE(buf, SVt_PV);
    SvPV_nolen(buf);
    buf_len = SvCUR(buf);
    d = SvGROW(buf, buf_len + len);
    rv = _read_timeout(fileno, timeout, &d[offset], len);
    SvCUR_set(buf, (rv > 0) ? rv + buf_len : buf_len);
    SvPOK_only(buf);
    if (rv < 0) XSRETURN_UNDEF;
    RETVAL = (unsigned long)rv;
  OUTPUT:
    RETVAL

unsigned long
write_timeout(fileno, buf, len, offset, timeout)
    int fileno
    SV * buf
    ssize_t len
    ssize_t offset
    double timeout
  PREINIT:
    char * d;
    ssize_t rv;
  CODE:
    SvUPGRADE(buf, SVt_PV);
    d = SvPV_nolen(buf);
    rv = _write_timeout(fileno, timeout, &d[offset], len);
    if (rv < 0) XSRETURN_UNDEF;
    RETVAL = (unsigned long)rv;
  OUTPUT:
    RETVAL

unsigned long
write_all(fileno, buf, offset, timeout)
    int fileno
    SV * buf
    ssize_t offset
    double timeout
  PREINIT:
    char * d;
    ssize_t buf_len;
    ssize_t rv;
    ssize_t written = 0;
  CODE:
    SvUPGRADE(buf, SVt_PV);
    d = SvPV_nolen(buf);
    buf_len = SvCUR(buf);
    written = 0;
    while ( buf_len > written ) {
      rv = _write_timeout(fileno, timeout, &d[written], buf_len - written);
      if ( rv <= 0 ) {
        break;
      }
      written += rv;
    }
    if (rv < 0) XSRETURN_UNDEF;
    RETVAL = (unsigned long)written;
  OUTPUT:
    RETVAL

void
close_client(fileno)
    int fileno
  CODE:
    close(fileno);

unsigned long
write_psgi_response(fileno, timeout, headers, body)
    int fileno
    double timeout
    SV * headers
    AV * body
  PREINIT:
    ssize_t rv;
    STRLEN len;
    ssize_t iovcnt;
    ssize_t vec_offset;
    ssize_t written;
    int count;
    int i;
    struct iovec * v;
  CODE:
    iovcnt = 1 + av_len(body) + 1;
    {
      struct iovec v[iovcnt]; // Needs C99 compiler
      v[0].iov_base = svpv2char(headers, &len);
      v[0].iov_len = len;
      iovcnt = 1;
      for (i=0; i < av_len(body) + 1; i++ ) {
        if (!SvOK(*av_fetch(body,i,0))) {
          continue;
        }
        v[iovcnt].iov_base = svpv2char(*av_fetch(body,i,0), &len);
        v[iovcnt].iov_len = len;
        iovcnt++;
      }

      vec_offset = 0;
      written = 0;
      while ( iovcnt - vec_offset > 0 ) {
        count = (iovcnt > IOV_MAX) ? IOV_MAX : iovcnt;
        rv = _writev_timeout(fileno, timeout,  &v[vec_offset], count - vec_offset);
        if ( rv <= 0 ) {
          // error or disconnected
          break;
        }
        written += rv;
        while ( rv > 0 ) {
          if ( rv >= v[vec_offset].iov_len ) {
            rv -= v[vec_offset].iov_len;
            vec_offset++;
          }
          else {
            v[vec_offset].iov_base = (char*)v[vec_offset].iov_base + rv;
            v[vec_offset].iov_len -= rv;
            rv = 0;
          }
        }
      }
    }
    if (rv < 0) XSRETURN_UNDEF;
    RETVAL = (unsigned long) written;
  OUTPUT:
    RETVAL

