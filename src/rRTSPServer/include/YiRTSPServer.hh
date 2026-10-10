// SPDX-License-Identifier: GPL-3.0-only
#ifndef YI_RTSP_SERVER_HH
#define YI_RTSP_SERVER_HH

#include "RTSPServer.hh"

// Keep ordinary viewers separate from clients requesting speaker audio.
class YiRTSPServer: public RTSPServer {
public:
    static YiRTSPServer* createNew(UsageEnvironment& env, Port port,
                                  UserAuthenticationDatabase* authDB);

protected:
    YiRTSPServer(UsageEnvironment& env, int ipv4, int ipv6, Port port,
                 UserAuthenticationDatabase* authDB);
    virtual ClientConnection* createNewClientConnection(int socket,
                                     struct sockaddr_storage const& address);
    virtual ClientSession* createNewClientSession(u_int32_t sessionId);

    class Connection: public RTSPClientConnection {
    public:
        Connection(YiRTSPServer& server, int socket,
                   struct sockaddr_storage const& address);
    protected:
        virtual void handleCmd_DESCRIBE(char const* pre, char const* suffix,
                                        char const* request);
        virtual void handleCmd_DESCRIBE_afterLookup(ServerMediaSession* session);
    private:
        bool fWantBackchannel;
    };

    class Session: public RTSPClientSession {
    public:
        Session(YiRTSPServer& server, u_int32_t id): RTSPClientSession(server, id) {}
    protected:
        virtual void handleCmd_SETUP(RTSPClientConnection* connection,
                     char const* pre, char const* suffix, char const* request);
        virtual void handleCmd_withinSession(RTSPClientConnection* connection,
                     char const* command, char const* pre, char const* suffix,
                     char const* request);
    };
};
#endif
