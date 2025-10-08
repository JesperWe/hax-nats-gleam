
## NATS Core Wire API Messages

| Message Type | Pattern | Direction | Description |
|--------------|---------|-----------|-------------|
| **Connection** |
| CONNECT | `CONNECT {json}` | Client → Server | Initial connection with client info |
| INFO | `INFO {json}` | Server → Client | Server information and capabilities |
| PING | `PING` | Bidirectional | Keepalive ping |
| PONG | `PONG` | Bidirectional | Keepalive pong response |
| **Publishing** |
| PUB | `PUB <subject> [reply] <#bytes>\r\n[payload]` | Client → Server | Publish message |
| HPUB | `HPUB <subject> [reply] <#header_bytes> <#total_bytes>\r\n[headers]\r\n[payload]` | Client → Server | Publish with headers |
| **Subscribing** |
| SUB | `SUB <subject> [queue] <sid>` | Client → Server | Subscribe to subject |
| UNSUB | `UNSUB <sid> [max_msgs]` | Client → Server | Unsubscribe |
| **Message Delivery** |
| MSG | `MSG <subject> <sid> [reply] <#bytes>\r\n[payload]` | Server → Client | Deliver message |
| HMSG | `HMSG <subject> <sid> [reply] <#header_bytes> <#total_bytes>\r\n[headers]\r\n[payload]` | Server → Client | Deliver message with headers |
| **Errors** |
| +OK | `+OK` | Server → Client | Acknowledge successful operation |
| -ERR | `-ERR <error>` | Server → Client | Protocol or permission error |

## JetStream Wire API Messages

All JetStream API calls follow the pattern: `$JS.API.<operation>` with JSON payloads.

| API Category | Subject Pattern                                        | Request Type | Response Type | Description |
|--------------|--------------------------------------------------------|--------------|---------------|-------------|
| **Account Info** |
| Account Info | `$JS.API.INFO`                                         | Empty/`{}` | AccountInfoResponse | Get account information |
| **Stream Management** |
| Stream Info | `$JS.API.STREAM.INFO.<stream>`                         | Empty/`{}` | StreamInfoResponse | Get stream information |
| Stream List | `$JS.API.STREAM.LIST`                                  | StreamListRequest | StreamListResponse | List all streams |
| Stream Names | `$JS.API.STREAM.NAMES`                                 | StreamNamesRequest | StreamNamesResponse | Get stream names only |
| Create Stream | `$JS.API.STREAM.CREATE.<stream>`                       | StreamConfig | StreamInfoResponse | Create new stream |
| Update Stream | `$JS.API.STREAM.UPDATE.<stream>`                       | StreamConfig | StreamInfoResponse | Update existing stream |
| Delete Stream | `$JS.API.STREAM.DELETE.<stream>`                       | Empty/`{}` | SuccessResponse | Delete stream |
| Purge Stream | `$JS.API.STREAM.PURGE.<stream>`                        | StreamPurgeRequest | PurgeResponse | Purge stream messages |
| **Stream Messages** |
| Get Message | `$JS.API.STREAM.MSG.GET.<stream>`                      | MsgGetRequest | StoredMsg | Get specific message |
| Delete Message | `$JS.API.STREAM.MSG.DELETE.<stream>`                   | MsgDeleteRequest | SuccessResponse | Delete specific message |
| **Consumer Management** |
| Consumer Info | `$JS.API.CONSUMER.INFO .<stream>.<consumer>`           | Empty/`{}` | ConsumerInfoResponse | Get consumer information |
| Consumer List | `$JS.API.CONSUMER.LIST .<stream>`                      | ConsumerListRequest | ConsumerListResponse | List consumers for stream |
| Consumer Names | `$JS.API.CONSUMER.NAMES .<stream>`                     | ConsumerNamesRequest | ConsumerNamesResponse | Get consumer names only |
| Create Consumer | `$JS.API.CONSUMER.CREATE .<stream>`                    | ConsumerConfig | ConsumerInfoResponse | Create new consumer |
| Create Durable | `$JS.API.CONSUMER.DURABLE.CREATE .<stream>.<consumer>` | ConsumerConfig | ConsumerInfoResponse | Create durable consumer |
| Delete Consumer | `$JS.API.CONSUMER.DELETE .<stream>.<consumer>`         | Empty/`{}` | SuccessResponse | Delete consumer |
| **Consumer Operations** |
| Next Message | `$JS.API.CONSUMER.MSG.NEXT .<stream>.<consumer>`       | NextRequest | Message | Request next message |
| **Key-Value Store** |
| KV Bucket Info | `$JS.API.STREAM.INFO.KV_<bucket>`                      | Empty/`{}` | StreamInfoResponse | Get KV bucket info |
| KV Create | `$JS.API.STREAM.CREATE.KV_<bucket>`                    | StreamConfig | StreamInfoResponse | Create KV bucket |
| KV Delete | `$JS.API.STREAM.DELETE.KV_<bucket>`                    | Empty/`{}` | SuccessResponse | Delete KV bucket |
| **Object Store** |
| Object Info | `$JS.API.STREAM.INFO.OBJ_<bucket>`                     | Empty/`{}` | StreamInfoResponse | Get object store info |
| Object Create | `$JS.API.STREAM.CREATE.OBJ_<bucket>`                   | StreamConfig | StreamInfoResponse | Create object store |
| Object Delete | `$JS.API.STREAM.DELETE.OBJ_<bucket>`                   | Empty/`{}` | SuccessResponse | Delete object store |

### JetStream Advisory Messages

| Advisory Type | Subject Pattern                                            | Description |
|---------------|------------------------------------------------------------|-------------|
| Stream Action | `$JS.EVENT.ADVISORY.STREAM.CREATED.<stream>`               | Stream created |
| Stream Action | `$JS.EVENT.ADVISORY.STREAM.DELETED.<stream>`               | Stream deleted |
| Stream Action | `$JS.EVENT.ADVISORY.STREAM.UPDATED.<stream>`               | Stream updated |
| Consumer Action | `$JS.EVENT.ADVISORY.CONSUMER.CREATED .<stream>.<consumer>` | Consumer created |
| Consumer Action | `$JS.EVENT.ADVISORY.CONSUMER.DELETED .<stream>.<consumer>` | Consumer deleted |
| API Audit | `$JS.EVENT.ADVISORY.API`                                   | API access audit |
| Stream Snapshot | `$JS.EVENT.ADVISORY.STREAM .SNAPSHOT_CREATE.<stream>`      | Snapshot creation |
| Stream Snapshot | `$JS.EVENT.ADVISORY.STREAM .SNAPSHOT_COMPLETE.<stream>`    | Snapshot completion |
| Stream Restore | `$JS.EVENT.ADVISORY.STREAM .RESTORE_CREATE.<stream>`       | Restore creation |
| Stream Restore | `$JS.EVENT.ADVISORY.STREAM .RESTORE_COMPLETE.<stream>`     | Restore completion |

### JetStream Metrics

| Metric Type | Subject Pattern | Description |
|-------------|----------------|-------------|
| Consumer Delivery | `$JS.EVENT.METRIC.CONSUMER.ACK.<stream>.<consumer>` | Message acknowledgment |
| Consumer Delivery | `$JS.EVENT.METRIC.CONSUMER.DELIVERY_EXCEEDED.<stream>.<consumer>` | Max delivery exceeded |
| Stream Action | `$JS.EVENT.METRIC.STREAM.LEADER_ELECTED.<stream>` | Stream leader election |

### Special JetStream Subjects

| Subject | Purpose | Direction |
|---------|---------|-----------|
| `$JS.ACK.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<tm>.<pending>` | Message acknowledgment | Client → Server |
| `$JS.NAK.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<tm>.<pending>` | Message negative acknowledgment | Client → Server |
| `$JS.TERM.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<tm>.<pending>` | Terminate message redelivery | Client → Server |
| `$JS.WPI.<stream>.<consumer>.<delivered>.<sseq>.<cseq>.<tm>.<pending>` | Work in progress | Client → Server |

**Notes:**
- All JetStream API requests expect JSON payloads and return JSON responses
- Error responses follow the format: `{"error": {"code": <code>, "description": "<description>"}}`
- Success responses typically include: `{"type": "io.nats.jetstream.api.v1.<response_type>", ...}`
- Consumer message delivery can be push-based (to configured subject) or pull-based (via `MSG.NEXT` API)