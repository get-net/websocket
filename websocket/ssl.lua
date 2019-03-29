#!/usr/bin/env tarantool

local TIMEOUT_INFINITY      = 500 * 365 * 86400
local LIMIT_INFINITY = 2147483647

local log = require('log')
local ffi = require('ffi')
local socket = require('socket')
local buffer = require('buffer')
local clock = require('clock')
local errno = require('errno')

ffi.cdef[[

 typedef struct SSL_METHOD {} SSL_METHOD;
 typedef struct SSL_CTX {} SSL_CTX;
 typedef struct SSL {} SSL;
 typedef struct ossl_init_settings_st OPENSSL_INIT_SETTINGS;

 const SSL_METHOD *TLS_method(void);
 const SSL_METHOD *TLS_server_method(void);
 const SSL_METHOD *TLS_client_method(void);

 const SSL_METHOD *SSLv23_method(void);
 const SSL_METHOD *SSLv23_server_method(void);
 const SSL_METHOD *SSLv23_client_method(void);

 const SSL_METHOD *SSLv3_method(void);
 const SSL_METHOD *SSLv3_server_method(void);
 const SSL_METHOD *SSLv3_client_method(void);

 const SSL_METHOD *TLSv1_method(void);
 const SSL_METHOD *TLSv1_server_method(void);
 const SSL_METHOD *TLSv1_client_method(void);

 const SSL_METHOD *TLSv1_1_method(void);
 const SSL_METHOD *TLSv1_1_server_method(void);
 const SSL_METHOD *TLSv1_1_client_method(void);

 const SSL_METHOD *TLSv1_2_method(void);
 const SSL_METHOD *TLSv1_2_server_method(void);
 const SSL_METHOD *TLSv1_2_client_method(void);

 const SSL_METHOD *DTLS_method(void);
 const SSL_METHOD *DTLS_server_method(void);
 const SSL_METHOD *DTLS_client_method(void);

 const SSL_METHOD *DTLSv1_method(void);
 const SSL_METHOD *DTLSv1_server_method(void);
 const SSL_METHOD *DTLSv1_client_method(void);

 const SSL_METHOD *DTLSv1_2_method(void);
 const SSL_METHOD *DTLSv1_2_server_method(void);
 const SSL_METHOD *DTLSv1_2_client_method(void);

 int OPENSSL_init_ssl(uint64_t opts, const OPENSSL_INIT_SETTINGS *settings);
 int SSL_library_init(void);
 void SSL_load_error_strings(void);

 SSL_CTX *SSL_CTX_new(const SSL_METHOD *method);
 int SSL_CTX_up_ref(SSL_CTX *ctx);
 void SSL_CTX_free(SSL_CTX *);

 int SSL_CTX_use_certificate_file(SSL_CTX *ctx, const char *file, int type);
 int SSL_CTX_use_PrivateKey_file(SSL_CTX *ctx, const char *file, int type);

 SSL *SSL_new(SSL_CTX *ctx);
 void SSL_free(SSL *ssl);

 int SSL_set_fd(SSL *s, int fd);

 void SSL_set_connect_state(SSL *s);
 void SSL_set_accept_state(SSL *s);

 int SSL_write(SSL *ssl, const void *buf, int num);
 int SSL_read(SSL *ssl, void *buf, int num);

 int SSL_pending(const SSL *ssl);
 int SSL_has_pending(const SSL *s);

 void ERR_clear_error(void);
 char *ERR_error_string(unsigned long e, char *buf);
 unsigned long ERR_peek_last_error(void);

 int SSL_get_error(const SSL *s, int ret_code);

 typedef socklen_t uint32;
 int getsockopt(int sockfd, int level, int optname, void *optval,
                socklen_t *optlen);

 int setsockopt(int sockfd, int level, int optname,
                const void *optval, socklen_t optlen);

  void *memmem(const void *haystack, size_t haystacklen,
        const void *needle, size_t needlelen);
]]

ffi.C.OPENSSL_init_ssl(0, NULL)
-- ffi.C.SSL_load_error_strings()

local methods = {
--    sslv23 = ffi.C.SSLv23_method(),
--    sslv3 = ffi.C.SSLv3_method(),
    tlsv1 = ffi.C.TLSv1_method(),
    tlsv11 = ffi.C.TLSv1_1_method(),
}

local function slice_wait(timeout, starttime)
    if timeout == nil then
        return nil
    end

    return timeout - (clock.time() - starttime)
end

local X509_FILETYPE_PEM       =1
local X509_FILETYPE_ASN1      =2
local X509_FILETYPE_DEFAULT   =3

local function ctx(method)
    method = method or ffi.C.TLSv1_method()

    ffi.C.ERR_clear_error()
    local newctx =
        ffi.gc(ffi.C.SSL_CTX_new(method), ffi.C.SSL_CTX_free)

    return newctx
end

local function ctx_use_private_key_file(ctx, pem_file)
    if ffi.C.SSL_CTX_use_PrivateKey_file(ctx, pem_file, X509_FILETYPE_PEM) ~= 1 then
        return false
    end
    return true
end

local function ctx_use_certificate_file(ctx, pem_file)
    if ffi.C.SSL_CTX_use_certificate_file(ctx, pem_file, X509_FILETYPE_PEM) ~= 1 then
        return false
    end
    return true
end

local default_ctx = ctx(methods.sslv23)

local SSL_ERROR_NONE                  =0
local SSL_ERROR_SSL                   =1
local SSL_ERROR_WANT_READ             =2
local SSL_ERROR_WANT_WRITE            =3
local SSL_ERROR_WANT_X509_LOOKUP      =4
local SSL_ERROR_SYSCALL               =5 -- look at error stack/return value/errno
local SSL_ERROR_ZERO_RETURN           =6
local SSL_ERROR_WANT_CONNECT          =7
local SSL_ERROR_WANT_ACCEPT           =8

local sslsocket = {
    __newindex = function(table, key, value)
        error("Attempt to modify read-only sslsocket properties "..key)
    end,
}
sslsocket.__index = sslsocket

local WAIT_FOR_READ =1
local WAIT_FOR_WRITE =2

function sslsocket.write(self, data, timeout)
    local start = clock.time()

    local size = #data
    local s = ffi.cast('const char *', data)

    local mode = WAIT_FOR_WRITE

    while true do
        local rc = nil
        if mode == WAIT_FOR_READ then
            rc = self.sock:readable(slice_wait(timeout, start))
        elseif mode == WAIT_FOR_WRITE then
            rc = self.sock:writable(slice_wait(timeout, start))
        else
            assert(false)
        end

        if not rc then
            self.sock._errno = errno.ETIMEDOUT
            return nil, 'Timeout exceeded'
        end

        ffi.C.ERR_clear_error()
        local num = ffi.C.SSL_write(self.ssl, s, size);
        if num <= 0 then
            local ssl_error = ffi.C.SSL_get_error(self.ssl, num);
            if ssl_error == SSL_ERROR_WANT_WRITE then
                mode = WAIT_FOR_WRITE
            elseif ssl_error == SSL_ERROR_WANT_READ then
                mode = WAIT_FOR_READ
            elseif ssl_error == SSL_ERROR_SYSCALL then
                return nil, self.sock:error()
            elseif ssl_error == SSL_ERROR_ZERO_RETURN then
                return nil, 'TLS channel closed'
            else
                local error_string = ffi.string(ffi.C.ERR_error_string(ssl_error, nil))
                return nil, error_string
            end
        else
            return num
        end
    end
end

function sslsocket.getaddrinfo(self)
    return self.sock:getaddrinfo()
end

function sslsocket.shutdown(self, how)
    self.sock:shutdown(how)
    return self.sock:shutdown(how)
end

function sslsocket.close(self)
    return self.sock:close()
end

function sslsocket.error(self)
    local error_string =
        ffi.string(ffi.C.ERR_error_string(ffi.C.ERR_peek_last_error(), nil))

    return self.sock:error() or error_string
end

function sslsocket.errno(self)
    return self.sock:errno() or ffi.C.ERR_peek_last_error()
end

function sslsocket.setsockopt(self, level, name, value)
    return self.sock:setsockopt(level, name, value)
end

function sslsocket.getsockopt(self, level, name)
    return self.sock:getsockopt(level, name)
end

function sslsocket.name(self)
    return self.sock:name()
end

function sslsocket.peer(self)
    return self.sock:peer()
end

function sslsocket.fd(self)
    return self.sock:fd()
end

function sslsocket.nonblock(self, nb)
    return self.sock:nonblock(nb)
end

local function sysread(self, charptr, size, timeout)
    local start = clock.time()

    local mode = WAIT_FOR_READ
    while true do
        local rc = nil
        if mode == WAIT_FOR_READ then
            if ffi.C.SSL_pending(self.ssl) > 0 then
                rc = true
            else
                rc = self.sock:readable(slice_wait(timeout, start))
            end
        elseif mode == WAIT_FOR_WRITE then
            rc = self.sock:writable(slice_wait(timeout, start))
        else
            assert(false)
        end

        if not rc then
            self.sock._errno = errno.ETIMEDOUT
            return nil, 'Timeout exceeded'
        end

        ffi.C.ERR_clear_error()
        local num = ffi.C.SSL_read(self.ssl, charptr, size);
        if num <= 0 then
            local ssl_error = ffi.C.SSL_get_error(self.ssl, num);
            if ssl_error == SSL_ERROR_WANT_WRITE then
                mode = WAIT_FOR_WRITE
            elseif ssl_error == SSL_ERROR_WANT_READ then
                mode = WAIT_FOR_READ
            elseif ssl_error == SSL_ERROR_SYSCALL then
                return nil, self.sock:error()
            elseif ssl_error == SSL_ERROR_ZERO_RETURN then
                return nil, 'TLS channel closed'
            else
                local error_string = ffi.string(ffi.C.ERR_error_string(ssl_error, nil))
                return nil, error_string
            end
        else
            return num
        end
    end
end

local function read(self, limit, timeout, check, ...)
    assert(limit >= 0)

    local start = clock.time()

    limit = math.min(limit, LIMIT_INFINITY)
    local rbuf = self.rbuf
    if rbuf == nil then
        rbuf = buffer.ibuf()
        rawset(self, 'rbuf', rbuf)
    end

    local len = check(self, limit, ...)
    if len ~= nil then
        local data = ffi.string(rbuf.rpos, len)
        rbuf.rpos = rbuf.rpos + len
        return data
    end

    while true do
        assert(rbuf:size() < limit)
        local to_read = math.min(limit - rbuf:size(), buffer.READAHEAD)
        local data = rbuf:reserve(to_read)
        assert(rbuf:unused() >= to_read)

        local res, err = sysread(self, data, rbuf:unused(), slice_wait(timeout, start))
        if res == 0 then -- eof
            local len = rbuf:size()
            local data = ffi.string(rbuf.rpos, len)
            rbuf.rpos = rbuf.rpos + len
            return data
        elseif res ~= nil then
            rbuf.wpos = rbuf.wpos + res
            local len = check(self, limit, ...)
            if len ~= nil then
                local data = ffi.string(rbuf.rpos, len)
                rbuf.rpos = rbuf.rpos + len
                return data
            end
        else
            return nil, err
        end
    end

    -- return nil
end

local function check_limit(self, limit)
    if self.rbuf:size() >= limit then
        return limit
    end
    return nil
end

local function check_delimiter(self, limit, eols)
    if limit == 0 then
        return 0
    end
    local rbuf = self.rbuf
    if rbuf:size() == 0 then
        return nil
    end

    local shortest
    for i, eol in ipairs(eols) do
        local data = ffi.C.memmem(rbuf.rpos, rbuf:size(), eol, #eol)
        if data ~= nil then
            local len = ffi.cast('char *', data) - rbuf.rpos + #eol
            if shortest == nil or shortest > len then
                shortest = len
            end
        end
    end
    if shortest ~= nil and shortest <= limit then
        return shortest
    elseif limit <= rbuf:size() then
        return limit
    end
    return nil
end

function sslsocket.read(self, opts, timeout)
    timeout = timeout or TIMEOUT_INFINITY
    if type(opts) == 'number' then
        return read(self, opts, timeout, check_limit)
    elseif type(opts) == 'string' then
        return read(self, LIMIT_INFINITY, timeout, check_delimiter, { opts })
    elseif type(opts) == 'table' then
        local chunk = opts.chunk or opts.size or LIMIT_INFINITY
        local delimiter = opts.delimiter or opts.line
        if delimiter == nil then
            return read(self, chunk, timeout, check_limit)
        elseif type(delimiter) == 'string' then
            return read(self, chunk, timeout, check_delimiter, { delimiter })
        elseif type(delimiter) == 'table' then
            return read(self, chunk, timeout, check_delimiter, delimiter)
        end
    end
    error('Usage: s:read(delimiter|chunk|{delimiter = x, chunk = x}, timeout)')
end

local function tcp_connect(host, port, timeout, sslctx)
    sslctx = sslctx or default_ctx

    ffi.C.ERR_clear_error()
    local ssl = ffi.gc(ffi.C.SSL_new(sslctx),
                       ffi.C.SSL_free)
    if ssl == nil then
        return nil, 'SSL_new failed'
    end

    local sock = socket.tcp_connect(host, port, timeout)
    if not sock then
        return nil, 'tcp connect failed'
    end

    sock:nonblock(true)

    ffi.C.ERR_clear_error()
    local rc = ffi.C.SSL_set_fd(ssl, sock:fd())
    if rc == 0 then
        sock:close()
        return nil, 'SSL_set_fd failed'
    end

    ffi.C.ERR_clear_error()
    ffi.C.SSL_set_connect_state(ssl);

    local self = setmetatable({}, sslsocket)
    rawset(self, 'sock', sock)
    rawset(self, 'ctx', sslctx)
    rawset(self, 'ssl', ssl)

    return self
end

local function wrap_accepted_socket(sock, sslctx)
    sslctx = sslctx or default_ctx

    ffi.C.ERR_clear_error()
    local ssl = ffi.gc(ffi.C.SSL_new(sslctx),
                       ffi.C.SSL_free)
    if ssl == nil then
        sock:close()
        return nil, 'SSL_new failed'
    end

    sock:nonblock(true)

    ffi.C.ERR_clear_error()
    local rc = ffi.C.SSL_set_fd(ssl, sock:fd())
    if rc == 0 then
        sock:close()
        return nil, 'SSL_set_fd failed'
    end

    ffi.C.ERR_clear_error()
    ffi.C.SSL_set_accept_state(ssl);

    local self = setmetatable({}, sslsocket)
    rawset(self, 'sock', sock)
    rawset(self, 'ctx', sslctx)
    rawset(self, 'ssl', ssl)
    return self
end

local function tcp_server(host, port, handler_function, timeout, sslctx)
    sslctx = sslctx or default_ctx

    local handler = function (sock, from)
        local self, err = wrap_accepted_socket(sock, sslctx)
        if not self then
            log.info(err)
        else
            handler_function(self, from)
        end
    end

    return socket.tcp_server(host, port, handler, timeout)
end

local function accept(server, ctx)
    local sock = server:accept()
    if sock == nil then
        return nil
    end

    return wrap_accepted_socket(sock, ctx)
end

return {
    methods = methods,
    ctx = ctx,
    ctx_use_private_key_file = ctx_use_private_key_file,
    ctx_use_certificate_file = ctx_use_certificate_file,

    tcp_connect = tcp_connect,
    tcp_server = tcp_server,

    SHUT_RDWR = socket.SHUT_RDWR,
    SHUT_RD = socket.SHUT_RD,
    SHUT_WR = socket.SHUT_WR,

    wrap_accepted_socket = wrap_accepted_socket,
    accept = accept,
}
