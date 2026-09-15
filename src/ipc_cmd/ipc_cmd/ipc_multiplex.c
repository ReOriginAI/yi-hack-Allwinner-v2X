#include "ipc_multiplex.h"
#include <pthread.h>

// May be set to true using the "IPC_MULTIPLEX_DEBUG" environment
// variable for debugging purposes.
bool debug = false;

// Initialize the mirror handles once, including concurrent broker threads.
static pthread_once_t initialize_once = PTHREAD_ONCE_INIT;
static int first_queue = 2;
static int last_queue = 2;

// The message queue onto which all messages will be forwarded.
mqd_t ipc_mq[10];

// The original mq_receive function.
ssize_t (*original_mq_receive)(mqd_t, char*, size_t, unsigned int*);

/**
* Initializes the ipc_dispatch_x message queues and looks up the
* original mq_receive function.
**/
void ipc_multiplex_initialize() {

    int i;

    // Enable debug mode if requested
    if (getenv(ENV_IPC_MULTIPLEX_DEBUG)) {
        debug = true;
    }

    // Normal operation has one consumer: ipc2file on queue 2. Diagnostic
    // readers can request the historical nine-queue fan-out before startup.
    const char *all = getenv("IPC_MULTIPLEX_ALL");
    if (all && strcmp(all, "1") == 0) {
        first_queue = 1;
        last_queue = 9;
    }

    // Prepare attributes for opening message queues.
    struct mq_attr attr = {
        .mq_flags = 0,
        .mq_maxmsg = 64,
        .mq_msgsize = IPC_MESSAGE_MAX_SIZE,
        .mq_curmsgs = 0
    };

    char queue_name[64];
    for (i = first_queue; i <= last_queue; i++) {
        sprintf(queue_name, "%s_%d", IPC_QUEUE_NAME, i);

        // Open the message queue or create a new one if it does not exist
        ipc_mq[i] = mq_open(queue_name, O_RDWR | O_CREAT | O_NONBLOCK, 0644, &attr);
        if(ipc_mq[i] == INVALID_QUEUE) {
            fprintf(stderr, "*** [IPC_MULTIPLEX] Can't open mqueue %s. Error: %s\n", queue_name, strerror(errno));
            // A failed diagnostic/event sink must not kill the vendor broker.
        }
    }

    // Find original mq_receive symbol and store it for later usage
    original_mq_receive = dlsym(RTLD_NEXT, "mq_receive");
}

/**
* Extracts the message's target.
*/
inline unsigned int get_message_target(char *msg_ptr) {
    return *((unsigned int*) &(msg_ptr[MESSAGE_TARGET_OFFSET]));
}

/**
* First, calls the original mq_receive function and then forwards the received
* message onto the ipc_dispatch_x message queues.
**/
ssize_t mq_receive(mqd_t mqdes, char *msg_ptr, size_t msg_len, unsigned int *msg_prio) {

    int i;

    // Initialize resources on first call.
    int saved_errno = errno;
    pthread_once(&initialize_once, ipc_multiplex_initialize);
    if (!original_mq_receive) {
        errno = ENOSYS;
        return -1;
    }
    errno = saved_errno;

    // Call original function to preserve behaviour
    ssize_t bytes_read = original_mq_receive(mqdes, msg_ptr, msg_len, msg_prio);
    saved_errno = errno;
    if (bytes_read < 0)
        return bytes_read;

    if (debug) {
        fprintf(stderr, "*** [IPC_MULTIPLEX] ");
        for(i = 0; i < bytes_read; i++)
            fprintf(stderr, "%02x ", msg_ptr[i]);
        fprintf(stderr, "\n");
    }

    // Filter out messages not targeted at the ipc_dispatch queue.
//    if (get_message_target(msg_ptr) != MESSAGE_ID_IPC_DISPATCH) {
//        return bytes_read;
//    }

    // Resend the received message to the dispatch queues
    for (i = first_queue; i <= last_queue; i++) {
        if (ipc_mq[i] == INVALID_QUEUE)
            continue;

        // mq_send will fail with EAGAIN whenever the target message queue is full.
        if (mq_send(ipc_mq[i], msg_ptr, bytes_read, MESSAGE_PRIORITY) != 0 && errno != EAGAIN) {
            fprintf(stderr, "*** [IPC_MULTIPLEX] Resending message to %s_%d queue failed. error = %s\n", IPC_QUEUE_NAME, i, strerror(errno));
        };
    }

    // Return like the original function would do
    errno = saved_errno;
    return bytes_read;
}
