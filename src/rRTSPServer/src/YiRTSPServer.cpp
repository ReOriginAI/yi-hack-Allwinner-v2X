// SPDX-License-Identifier: GPL-3.0-only
#include "YiRTSPServer.hh"

#include <cstdio>
#include <cstring>
#include <string>
#include <strings.h>

static std::string streamPath(char const* path) {
    std::string result(path);
    return result.substr(0, result.find('?'));
}

static int backchannelQuery(char const* path) {
    char const* query = strchr(path, '?');
    if (query == NULL) return -1;
    std::string params(query + 1);
    size_t start = 0;
    while (start < params.size()) {
        size_t end = params.find('&', start);
        std::string param = params.substr(start, end - start);
        if (param == "backchannel=1") return 1;
        if (param == "backchannel=0") return 0;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return -1;
}

static bool requiresBackchannel(char const* request) {
    std::string lines(request);
    size_t start = lines.find("\r\n") + 2;
    while (start < lines.size()) {
        size_t end = lines.find("\r\n", start);
        if (end == std::string::npos || end == start) break;
        std::string line = lines.substr(start, end - start);
        if (strncasecmp(line.c_str(), "Require:", 8) == 0) {
            size_t pos = 8;
            while (pos < line.size()) {
                pos = line.find_first_not_of(" \t,", pos);
                if (pos == std::string::npos) break;
                size_t last = line.find_first_of(" \t,", pos);
                if (line.substr(pos, last - pos) == "www.onvif.org/ver20/backchannel") return true;
                if (last == std::string::npos) break;
                pos = last;
            }
        }
        start = end + 2;
    }
    return false;
}

YiRTSPServer* YiRTSPServer::createNew(UsageEnvironment& env, Port port,
                                     UserAuthenticationDatabase* authDB) {
    int ipv4 = setUpOurSocket(env, port, AF_INET);
    int ipv6 = setUpOurSocket(env, port, AF_INET6);
    if (ipv4 < 0 && ipv6 < 0) return NULL;
    return new YiRTSPServer(env, ipv4, ipv6, port, authDB);
}

YiRTSPServer::YiRTSPServer(UsageEnvironment& env, int ipv4, int ipv6,
                         Port port, UserAuthenticationDatabase* authDB)
    : RTSPServer(env, ipv4, ipv6, port, authDB, 65) {}

GenericMediaServer::ClientConnection* YiRTSPServer::createNewClientConnection(
                            int socket, struct sockaddr_storage const& address) {
    return new Connection(*this, socket, address);
}

GenericMediaServer::ClientSession* YiRTSPServer::createNewClientSession(u_int32_t id) {
    return new Session(*this, id);
}

YiRTSPServer::Connection::Connection(YiRTSPServer& server, int socket,
                                   struct sockaddr_storage const& address)
    : RTSPClientConnection(server, socket, address), fWantBackchannel(false) {}

void YiRTSPServer::Connection::handleCmd_DESCRIBE(char const* pre,
                              char const* suffix, char const* request) {
    int query = backchannelQuery(suffix);
    if (query < 0) query = backchannelQuery(pre);
    fWantBackchannel = query >= 0 ? query == 1 : requiresBackchannel(request);
    // Preserve the original request for Digest authentication.
    RTSPClientConnection::handleCmd_DESCRIBE(streamPath(pre).c_str(),
                                            streamPath(suffix).c_str(), request);
}

void YiRTSPServer::Connection::handleCmd_DESCRIBE_afterLookup(ServerMediaSession* session) {
    RTSPClientConnection::handleCmd_DESCRIBE_afterLookup(session);
    if (fWantBackchannel) return;

    // Filter this connection's response, leaving the shared session untouched.
    // In ONVIF SDP, sendonly describes the client's reverse audio track.
    std::string response((char*)fResponseBuffer);
    size_t body = response.find("\r\n\r\n");
    if (body == std::string::npos) return;
    std::string sdp = response.substr(body + 4);
    size_t start = sdp.find("m=");
    while (start != std::string::npos) {
        size_t end = sdp.find("\r\nm=", start);
        if (end != std::string::npos) end += 2;
        std::string track = sdp.substr(start, end - start);
        if (track.find("\r\na=sendonly\r\n") != std::string::npos) {
            sdp.erase(start, end == std::string::npos ? end : end - start);
        } else {
            start = end;
        }
        if (start >= sdp.size()) break;
    }
    size_t length = response.find("Content-Length: ");
    if (length == std::string::npos) return;
    size_t end = response.find("\r\n", length);
    std::string header = response.substr(0, length) + "Content-Length: "
                       + std::to_string(sdp.size()) + response.substr(end, body + 4 - end);
    snprintf((char*)fResponseBuffer, sizeof fResponseBuffer, "%s%s", header.c_str(), sdp.c_str());
}

void YiRTSPServer::Session::handleCmd_SETUP(RTSPClientConnection* connection,
                      char const* pre, char const* suffix, char const* request) {
    RTSPClientSession::handleCmd_SETUP(connection, streamPath(pre).c_str(),
                                      streamPath(suffix).c_str(), request);
}

void YiRTSPServer::Session::handleCmd_withinSession(RTSPClientConnection* connection,
                      char const* command, char const* pre, char const* suffix,
                      char const* request) {
    RTSPClientSession::handleCmd_withinSession(connection, command,
                               streamPath(pre).c_str(), streamPath(suffix).c_str(), request);
}
