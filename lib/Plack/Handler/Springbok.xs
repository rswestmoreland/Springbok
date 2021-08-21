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
#ifndef __need_IOV_MAX
#define __need_IOV_MAX
#endif

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
#if defined(__FreeBSD__) || defined(__APPLE__)
# define IOV_MAX 128
#endif
#endif

#ifndef IOV_MAX
#  error "Unable to determine IOV_MAX from system headers"
#endif


#define MAX_HEADER_SIZE 16384
#define MAX_HEADER_NAME_LEN 1024
#define MAX_HEADERS         128
#if defined(__OpenBSD__)
#define READ_BUFSZ 16383
#else
#define READ_BUFSZ 16384
#endif
#define BAD_REQUEST "HTTP/1.0 400 Bad Request\r\nConnection: close\r\n\r\n400 Bad Request\r\n"
#define EXPECT_CONTINUE "HTTP/1.1 100 Continue\r\n\r\n"
#define EXPECT_FAILED "HTTP/1.1 417 Expectation Failed\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nExpectation Failed\r\n"
#define TOU(ch) (('a' <= ch && ch <= 'z') ? ch - ('a' - 'A') : ch)

static const char *DoW[] = {
  "Sun","Mon","Tue","Wed","Thu","Fri","Sat"
};
static const char *MoY[] = {
  "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"
};
static const char xdigit[16] = {'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'};

static HV *env_template;

/* stolen from HTTP::Status and Feersum */
/* Unmarked codes are from RFC 2616 */
/* See also: http://en.wikipedia.org/wiki/List_of_HTTP_status_codes */
static const char *
status_message (int code) {
  switch (code) {
    case 100: return "Continue";
    case 101: return "Switching Protocols";
    case 102: return "Processing";                      /* RFC 2518 (WebDAV) */
    case 200: return "OK";
    case 201: return "Created";
    case 202: return "Accepted";
    case 203: return "Non-Authoritative Information";
    case 204: return "No Content";
    case 205: return "Reset Content";
    case 206: return "Partial Content";
    case 207: return "Multi-Status";                    /* RFC 2518 (WebDAV) */
    case 208: return "Already Reported";              /* RFC 5842 */
    case 300: return "Multiple Choices";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 303: return "See Other";
    case 304: return "Not Modified";
    case 305: return "Use Proxy";
    case 307: return "Temporary Redirect";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 402: return "Payment Required";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 406: return "Not Acceptable";
    case 407: return "Proxy Authentication Required";
    case 408: return "Request Timeout";
    case 409: return "Conflict";
    case 410: return "Gone";
    case 411: return "Length Required";
    case 412: return "Precondition Failed";
    case 413: return "Request Entity Too Large";
    case 414: return "Request-URI Too Large";
    case 415: return "Unsupported Media Type";
    case 416: return "Request Range Not Satisfiable";
    case 417: return "Expectation Failed";
    case 418: return "I'm a teapot";              /* RFC 2324 */
    case 422: return "Unprocessable Entity";            /* RFC 2518 (WebDAV) */
    case 423: return "Locked";                          /* RFC 2518 (WebDAV) */
    case 424: return "Failed Dependency";               /* RFC 2518 (WebDAV) */
    case 425: return "No code";                         /* WebDAV Advanced Collections */
    case 426: return "Upgrade Required";                /* RFC 2817 */
    case 428: return "Precondition Required";
    case 429: return "Too Many Requests";
    case 431: return "Request Header Fields Too Large";
    case 449: return "Retry with";                      /* unofficial Microsoft */
    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout";
    case 505: return "HTTP Version Not Supported";
    case 506: return "Variant Also Negotiates";         /* RFC 2295 */
    case 507: return "Insufficient Storage";            /* RFC 2518 (WebDAV) */
    case 509: return "Bandwidth Limit Exceeded";        /* unofficial */
    case 510: return "Not Extended";                    /* RFC 2774 */
    case 511: return "Network Authentication Required";
    default: break;
  }
  /* default to the Nxx group names in RFC 2616 */
  if (100 <= code && code <= 199) {
    return "Informational";
  }
  else if (200 <= code && code <= 299) {
    return "Success";
    }
    else if (300 <= code && code <= 399) {
        return "Redirection";
    }
    else if (400 <= code && code <= 499) {
        return "Client Error";
    }
    else {
        return "Error";
    }
}

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
int store_path_info(pTHX_ HV* env, const char* src, size_t src_len) {
  size_t dlen = 0, i = 0;
  char *d;
  char s2, s3;
  SV * dst;

  dst = newSV(0);
  (void)SvUPGRADE(dst, SVt_PV);
  d = SvGROW(dst, src_len * 3 + 1);

  for (i = 0; i < src_len; i++ ) {
    if ( src[i] == '%' ) {
      if ( !isxdigit(src[i+1]) || !isxdigit(src[i+2]) ) {
        return -1;
      }
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
  *SvEND(dst) = '\0';
  SvPOK_only(dst);
  (void)hv_stores(env, "PATH_INFO", dst);
  return 1;
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
  if (minor_version > 1 || minor_version < 0 ) {
    ret = -1;
    goto done;
  }

  (void)hv_stores(env, "REQUEST_METHOD", newSVpvn(method, method_len));
  (void)hv_stores(env, "REQUEST_URI", newSVpvn(path, path_len));
  (void)hv_stores(env, "SCRIPT_NAME", newSVpvn("", 0));
  strcpy(tmp, "HTTP/1.");
  tmp[sizeof("HTTP/1.")-1] = '0' + minor_version;
  (void)hv_stores(env, "SERVER_PROTOCOL", newSVpvn(tmp, sizeof("HTTP/1.1")-1));

  /* PATH_INFO QUERY_STRING */
  path_len = find_ch(path, path_len, '#'); /* strip off all text after # after storing request_uri */
  question_at = find_ch(path, path_len, '?');
  if ( store_path_info(aTHX_ env, path, question_at) < 0 ) {
    hv_clear(env);
    ret = -1;
    goto done;
  }
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
      if ( !slot ) croak("ERROR: failed to create hash entry");
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
svpv2char(pTHX_ SV *sv, STRLEN *lp)
{
  if (SvGAMAGIC(sv))
    sv = sv_2mortal(newSVsv(sv));
  return SvPV(sv, *lp);
}


STATIC_INLINE
int
_accept(int fileno, struct sockaddr *addr, unsigned int addrlen) {
    int fd;
#ifdef HAVE_ACCEPT4
    fd = accept4(fileno, addr, &addrlen, SOCK_CLOEXEC|SOCK_NONBLOCK);
#else
    fd = accept(fileno, addr, &addrlen);
#endif
    if (fd < 0) {
      return fd;
    }
#ifndef HAVE_ACCEPT4
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
#endif
    return fd;
}


STATIC_INLINE
ssize_t
_writev_timeout(const int fileno, const double timeout, struct iovec *iovec, const int iovcnt, const int do_select ) {
    int rv;
    int nfound;
    struct pollfd wfds[1];
    if ( do_select == 1) goto WAIT_WRITE;
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

STATIC_INLINE
void
str_s(char * dst, size_t *dst_len, const char * src, int src_len) {
  int i;
  int dlen = *dst_len;
  for ( i=0; i<src_len; i++) {
    dst[dlen++] = src[i];
  }
  *dst_len = dlen;
}


STATIC_INLINE
void
str_i(char * dst, size_t * dst_len, int src, int fig) {
  int dlen = *dst_len + fig - 1;
  do {
    dst[dlen] = '0' + (src % 10);
    dlen--;
    src /= 10;
  } while( dlen >= *dst_len );
  *dst_len += fig;
}


STATIC_INLINE
int _date_line(char * date_line) {
    struct tm gtm;
    time_t lt;
    size_t i = 0;
    time(&lt);
    gmtime_r(&lt, &gtm);
    date_line[i++] = 'D';
    date_line[i++] = 'a';
    date_line[i++] = 't';
    date_line[i++] = 'e';
    date_line[i++] = ':';
    date_line[i++] = ' ';
    str_s(date_line, &i, DoW[gtm.tm_wday], 3);
    date_line[i++] = ',';
    date_line[i++] = ' ';
    str_i(date_line, &i, gtm.tm_mday, 2);
    date_line[i++] = ' ';
    str_s(date_line, &i, MoY[gtm.tm_mon], 3);
    date_line[i++] = ' ';
    str_i(date_line, &i, gtm.tm_year + 1900, 4);
    date_line[i++] = ' ';
    str_i(date_line, &i, gtm.tm_hour,2);
    date_line[i++] = ':';
    str_i(date_line, &i, gtm.tm_min,2);
    date_line[i++] = ':';
    str_i(date_line, &i, gtm.tm_sec,2);
    date_line[i++] = ' ';
    date_line[i++] = 'G';
    date_line[i++] = 'M';
    date_line[i++] = 'T';
    date_line[i++] = 13;
    date_line[i++] = 10;
    return i;
}

STATIC_INLINE
int _chunked_header(char *buf, ssize_t len) {
    int dlen = 0, i;
    ssize_t l = len;
    while ( l > 0 ) {
        dlen++;
        l /= 16;
    }
    i = dlen;
    buf[i++] = 13;
    buf[i++] = 10;
    buf[i+1] = 0;
    while ( len > 0 ) {
        buf[--dlen] = xdigit[len % 16];
        len /= 16;
    }
    return i;
}

MODULE = Plack::Handler::Springbok    PACKAGE = Plack::Handler::Springbok

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
    unsigned int len;
    char read_buf[MAX_HEADER_SIZE];
    HV * env;
    int flag = 1;
    ssize_t rv = 0;
    ssize_t buf_len;
    ssize_t reqlen;
PPCODE:
{
    /* if ( my ($conn, $buf, $env) = accept_buffer(fileno($server),timeout,tcp,host,port) */

    len = sizeof(cliaddr);
    fd = _accept(fileno, (struct sockaddr *)&cliaddr, len);
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
      (void)hv_stores(env,"REMOTE_PORT",newSViv(ntohs(cliaddr.sin_port)));
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

    /* expect */
    SV **expect_val = hv_fetch(env, "HTTP_EXPECT" , sizeof("HTTP_EXPECT")-1, 0);
    if (expect_val != NULL) {
      if ( strncmp(SvPV_nolen(*expect_val), "100-continue", SvCUR(*expect_val)) == 0 ) {
        rv = _write_timeout(fd, timeout, EXPECT_CONTINUE, sizeof(EXPECT_CONTINUE) - 1);
        if ( rv <= 0 ) {
          close(fd);
          goto badexit;
        }
      } else {
        rv = _write_timeout(fd, timeout, EXPECT_FAILED, sizeof(EXPECT_FAILED) - 1);
        close(fd);
        goto badexit;
      }
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
    if (!SvROK(rbuf)) croak("ERROR: buf must be RV");
    buf = SvRV(rbuf);
    if (!SvOK(buf)) {
      sv_setpvn(buf,"",0);
    }
    SvUPGRADE(buf, SVt_PV);
    SvPV_nolen(buf);
    buf_len = SvCUR(buf);
    if ( len > READ_BUFSZ ) {
      len = READ_BUFSZ;
    }
    d = SvGROW(buf, buf_len + len + 1);
    rv = _read_timeout(fileno, timeout, &d[offset], len);
    SvCUR_set(buf, (rv > 0) ? rv + buf_len : buf_len);
    *SvEND(buf) = '\0';
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
write_chunk(fileno, buf, offset, timeout)
    int fileno
    SV * buf
    ssize_t offset
    double timeout
  PREINIT:
    char *d;
    ssize_t buf_len;
    ssize_t rv = 0;
    ssize_t written = 0;
    ssize_t vec_offset = 0;
    int count =0;
    int remain;
    ssize_t iovcnt = 3;
    char chunked_header_buf[18];
  CODE:
    if ( !SvOK(buf) ) {
      RETVAL = 0;
      return;
    }
    SvUPGRADE(buf, SVt_PV);
    d = SvPV_nolen(buf);
    buf_len = SvCUR(buf);
    if ( buf_len == 0 ){
      RETVAL = 0;
      return;
    }

    {
      struct iovec v[iovcnt]; // Needs C99 compiler
      v[0].iov_len = _chunked_header(chunked_header_buf,buf_len);
      v[0].iov_base = chunked_header_buf;
      v[1].iov_len = buf_len;
      v[1].iov_base = d;
      v[2].iov_base = "\r\n";
      v[2].iov_len = sizeof("\r\n") -1;

      vec_offset = 0;
      written = 0;
      remain = iovcnt;
      while ( remain > 0 ) {
        count = (remain > IOV_MAX) ? IOV_MAX : remain;
        rv = _writev_timeout(fileno, timeout,  &v[vec_offset], count, (vec_offset == 0) ? 0 : 1);
        if ( rv <= 0 ) {
          warn("failed to writev: %zd errno:%d", rv, errno);
          // error or disconnected
          break;
        }
        written += rv;
        while ( rv > 0 ) {
          if ( (unsigned int)rv >= v[vec_offset].iov_len ) {
            rv -= v[vec_offset].iov_len;
            vec_offset++;
            remain--;
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
    RETVAL = (unsigned long)written;
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
    if ( !SvOK(buf) ) {
      RETVAL = 0;
      return;
    }
    SvUPGRADE(buf, SVt_PV);
    d = SvPV_nolen(buf);
    buf_len = SvCUR(buf);
    if ( buf_len == 0 ) {
      RETVAL = 0;
      return;
    }
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
write_informational_response(fileno, timeout, status_code, headers)
    int fileno
    double timeout
    int status_code
    AV * headers
  PREINIT:
    ssize_t rv;
    ssize_t iovcnt;
    ssize_t vec_offset;
    ssize_t written;
    int count;
    int remain;
    size_t i;
    struct iovec * iv;
    char status_line[512];
    char * key;
    char * val;
    STRLEN key_len = 0;
    STRLEN val_len = 0;
  CODE:
    if( (av_len(headers)+1) % 2 == 1 ) croak("ERROR: Odd number of element in header");
    iovcnt = 10 + (av_len(headers)+2)*2;
    {
      struct iovec iv[iovcnt]; // Needs C99 compiler
      /* status line */
      iovcnt = 0;
      i=0;
      status_line[i++] = 'H';
      status_line[i++] = 'T';
      status_line[i++] = 'T';
      status_line[i++] = 'P';
      status_line[i++] = '/';
      status_line[i++] = '1';
      status_line[i++] = '.';
      status_line[i++] = '1';
      status_line[i++] = ' ';
      str_i(status_line,&i,status_code,3);
      status_line[i++] = ' ';
      const char * message = status_message(status_code);
      str_s(status_line,&i, message, strlen(message));
      status_line[i++] = 13;
      status_line[i++] = 10;
      iv[iovcnt].iov_base = status_line;
      iv[iovcnt].iov_len = i;
      iovcnt++;

      i=0;
      while (i < av_len(headers) + 1 ) {
        /* key */
        key = svpv2char(aTHX_ *av_fetch(headers,i,0), &key_len);
        i++;
        val = svpv2char(aTHX_ *av_fetch(headers,i,0), &val_len);
        i++;
        iv[iovcnt].iov_base = key;
        iv[iovcnt].iov_len = key_len;
        iovcnt++;
        iv[iovcnt].iov_base = ": ";
        iv[iovcnt].iov_len = sizeof(": ") - 1;
        iovcnt++;
        /* value */
        iv[iovcnt].iov_base = val;
        iv[iovcnt].iov_len = val_len;
        iovcnt++;
        iv[iovcnt].iov_base = "\r\n";
        iv[iovcnt].iov_len = sizeof("\r\n") - 1;
        iovcnt++;
      }
      iv[iovcnt].iov_base = "\r\n";
      iv[iovcnt].iov_len = sizeof("\r\n") - 1;
      iovcnt++;

      vec_offset = 0;
      written = 0;
      remain = iovcnt;
      while ( remain > 0 ) {
        count = (remain > IOV_MAX) ? IOV_MAX : remain;
        rv = _writev_timeout(fileno, timeout,  &iv[vec_offset], count, (vec_offset == 0) ? 0 : 1);
        if ( rv <= 0 ) {
          warn("failed to writev: %zd errno:%d", rv, errno);
          // error or disconnected
          break;
        }
        written += rv;
        while ( rv > 0 ) {
          if ( (unsigned int)rv >= iv[vec_offset].iov_len ) {
            rv -= iv[vec_offset].iov_len;
            vec_offset++;
            remain--;
          }
          else {
            iv[vec_offset].iov_base = (char*)iv[vec_offset].iov_base + rv;
            iv[vec_offset].iov_len -= rv;
            rv = 0;
          }
        }
      }
    }

    if (rv < 0) XSRETURN_UNDEF;
    RETVAL = (unsigned long) written;
  OUTPUT:
    RETVAL


unsigned long
write_psgi_response(fileno, timeout, status_code, headers, body, use_chunkedv)
    int fileno
    double timeout
    int status_code
    AV * headers
    AV * body
    SV * use_chunkedv
  ALIAS:
    Plack::Handler::Springbok::write_psgi_response = 0
    Plack::Handler::Springbok::write_psgi_response_header = 1
  PREINIT:
    ssize_t rv;
    ssize_t iovcnt;
    ssize_t vec_offset;
    ssize_t written;
    int count;
    int remain;
    size_t i;
    struct iovec * v;
    char status_line[512];
    char date_line[512];
    char server_line[1032];
    char * key;
    char * val;
    STRLEN key_len = 0;
    STRLEN val_len;
    int date_pushed = 0;
    const char * s;
    char* d;
    ssize_t n;
    IV use_chunked;
    char * chunked_header_buf;

  CODE:
    if( (av_len(headers)+1) % 2 == 1 ) croak("ERROR: Odd number of element in header");
    use_chunked = SvIV(use_chunkedv);
    iovcnt = 10 + (av_len(headers)+2)*2 + (av_len(body) + 1);

    /* status_with_no_entity_body */
    if ( status_code < 200 || status_code == 204 || status_code == 304 ) {
      use_chunked = 0;
    }

    if ( use_chunked > 0 ) {
      iovcnt += (av_len(body)+1)*2;
    }
    Newx(chunked_header_buf, 18 * (av_len(body)+2), char);

    {
      struct iovec v[iovcnt]; // Needs C99 compiler
      /* status line */
      iovcnt = 0;
      i=0;
      status_line[i++] = 'H';
      status_line[i++] = 'T';
      status_line[i++] = 'T';
      status_line[i++] = 'P';
      status_line[i++] = '/';
      status_line[i++] = '1';
      status_line[i++] = '.';
      status_line[i++] = '1';
      status_line[i++] = ' ';
      str_i(status_line,&i,status_code,3);
      status_line[i++] = ' ';
      const char * message = status_message(status_code);
      str_s(status_line,&i, message, strlen(message));
      status_line[i++] = 13;
      status_line[i++] = 10;
      v[iovcnt].iov_base = status_line;
      v[iovcnt].iov_len = i;
      iovcnt++;

      /* for date header */
      iovcnt++;

      v[iovcnt].iov_base = "Server: gazelle\r\n";
      v[iovcnt].iov_len = sizeof("Server: gazelle\r\n")-1;
      iovcnt++;

      i=0;
      date_pushed = 0;
      while ( i < av_len(headers) + 1 ) {
        /* key */
        key = svpv2char(aTHX_ *av_fetch(headers,i,0), &key_len);
        i++;
        if ( strncasecmp(key,"Connection",key_len) == 0 ) {
          i++;
          continue;
        }

        val = svpv2char(aTHX_ *av_fetch(headers,i,0), &val_len);
        i++;

        if ( strncasecmp(key,"Date",key_len) == 0 ) {
          strcpy(date_line, "Date: ");
          for ( s=val, n = val_len, d=date_line+sizeof("Date: ")-1; n !=0; s++, --n, d++) {
            *d = *s;
          }
          date_line[sizeof("Date: ") -1 + val_len] = 13;
          date_line[sizeof("Date: ") -1 + val_len + 1] = 10;
          v[1].iov_base = date_line;
          v[1].iov_len = sizeof("Date: ") -1 + val_len + 2;
          date_pushed = 1;
          continue;
        } else if ( strncasecmp(key,"Server",key_len) == 0 ) {
          strcpy(server_line, "Server: ");
          for ( s=val, n = val_len, d=server_line+sizeof("Server: ")-1; n !=0; s++, --n, d++) {
            *d = *s;
          }
          server_line[sizeof("Server: ") -1 + val_len] = 13;
          server_line[sizeof("Server: ") -1 + val_len + 1] = 10;
          v[2].iov_base = server_line;
          v[2].iov_len = sizeof("Server: ") -1 + val_len + 2;
          continue;
        } else if ( strncasecmp(key,"Content-Length",key_len) == 0 || strncasecmp(key,"Transfer-Encoding",key_len) == 0) {
            use_chunked = 0;
        }

        v[iovcnt].iov_base = key;
        v[iovcnt].iov_len = key_len;
        iovcnt++;
        v[iovcnt].iov_base = ": ";
        v[iovcnt].iov_len = sizeof(": ") - 1;
        iovcnt++;
        /* value */
        v[iovcnt].iov_base = val;
        v[iovcnt].iov_len = val_len;
        iovcnt++;
        v[iovcnt].iov_base = "\r\n";
        v[iovcnt].iov_len = sizeof("\r\n") - 1;
        iovcnt++;
      }

      if ( date_pushed == 0 ) {
        v[1].iov_len = _date_line(date_line);
        v[1].iov_base = date_line;
      }

      if ( use_chunked > 0 ) {
          v[iovcnt].iov_base = "Transfer-Encoding: chunked\r\n";
          v[iovcnt].iov_len = sizeof("Transfer-Encoding: chunked\r\n") - 1;
          iovcnt++;
      }

      v[iovcnt].iov_base = "Connection: close\r\n\r\n";
      v[iovcnt].iov_len = sizeof("Connection: close\r\n\r\n") - 1;
      iovcnt++;

      size_t chb_offset = 0;
      for (i=0; i < av_len(body) + 1; i++ ) {
        SV **b = av_fetch(body,i,0);
        if (!SvOK(*b)) {
          continue;
        }
        d = svpv2char(aTHX_ *b, &val_len);
        if ( val_len < 1 ) {
          continue;
        }
        if ( use_chunked ) {
          v[iovcnt].iov_len = _chunked_header(&chunked_header_buf[chb_offset],val_len);
          v[iovcnt].iov_base = &chunked_header_buf[chb_offset];
          chb_offset += v[iovcnt].iov_len;
          iovcnt++;
        }
        v[iovcnt].iov_base = d;
        v[iovcnt].iov_len = val_len;
        iovcnt++;
        if ( use_chunked ) {
          v[iovcnt].iov_base = "\r\n";
          v[iovcnt].iov_len = sizeof("\r\n") -1;
          iovcnt++;
        }
      }

      if ( use_chunked && ix == 0 ) {
        v[iovcnt].iov_base = "0\r\n\r\n";
        v[iovcnt].iov_len = sizeof("0\r\n\r\n") - 1;
        iovcnt++;
      }

      vec_offset = 0;
      written = 0;
      remain = iovcnt;
      while ( remain > 0 ) {
        count = (remain > IOV_MAX) ? IOV_MAX : remain;
        rv = _writev_timeout(fileno, timeout,  &v[vec_offset], count, (vec_offset == 0) ? 0 : 1);
        if ( rv <= 0 ) {
          warn("failed to writev: %zd errno:%d", rv, errno);
          // error or disconnected
          break;
        }
        written += rv;
        while ( rv > 0 ) {
          if ( (unsigned int)rv >= v[vec_offset].iov_len ) {
            rv -= v[vec_offset].iov_len;
            vec_offset++;
            remain--;
          }
          else {
            v[vec_offset].iov_base = (char*)v[vec_offset].iov_base + rv;
            v[vec_offset].iov_len -= rv;
            rv = 0;
          }
        }
      }
    }
    sv_setiv(use_chunkedv, use_chunked);
    Safefree(chunked_header_buf);
    if (rv < 0) XSRETURN_UNDEF;
    RETVAL = (unsigned long) written;
  OUTPUT:
    RETVAL
