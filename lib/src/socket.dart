import 'dart:async';
import 'dart:io';
import 'package:phoenix_dart/src/ajax.dart';
import 'package:phoenix_dart/src/channel.dart';
import './timer.dart';
import './utils.dart';


class PhoenixSocket {

  Map<String, List<dynamic>> stateChangeCallbacks;
  Map<String, PhoenixChannel> channels;
  List<dynamic> sendBuffer;
  int ref;
  int timeout;
  Function defaultDecoder;
  Function defaultEncoder;
  Function encode;
  Function decode;
  int heartbeatIntervalMs;
  Function reconnectAfterMs;
  Function logger;
  Map<String, dynamic> params;
  String endPoint;
  Timer heartbeatTimer;
  String pendingHeartbeatRef;
  PhoenixTimer reconnectTimer;
  WebSocket conn;

  PhoenixSocket(String endPoint, { this.timeout, this.heartbeatIntervalMs = 30000,
    this.reconnectAfterMs, Function logger, this.params}){
    stateChangeCallbacks = <String, List<dynamic>>{"open": <dynamic>[],
      "close": <dynamic>[], "error": <dynamic>[], "message": <dynamic>[]};
    channels             = <String, PhoenixChannel>{};
    sendBuffer           = <dynamic>[];
    ref                  = 0;
    timeout              ??=  DEFAULT_TIMEOUT;
    defaultEncoder       = Serializer.encode;
    defaultDecoder       = Serializer.decode;
    encode ??= defaultEncoder;
    decode ??= defaultDecoder;
    reconnectAfterMs     ??= (int tries){
      print("####### tries $tries");
      return <int>[1000, 2000, 5000, 10000][tries - 1] ?? 10000;
    };
    this.logger               = logger ?? (String kind, String msg, [dynamic data]){}; // noop
    params               ??= <String, dynamic>{};
    this.endPoint             = "$endPoint/websocket";
    heartbeatTimer       = null;
    pendingHeartbeatRef  = null;
    reconnectTimer       = new PhoenixTimer(() {
      disconnect(() => connect());
    }, reconnectAfterMs);
  }

  String protocol(){ return endPoint.contains("https") ? "wss" : "ws"; }

  String endPointURL(){
    try {
      final String uri = Ajax.appendParams(
          Ajax.appendParams(endPoint, params), <String, dynamic>{"vsn": VSN});
      if (uri[0] != "/") {
        return uri;
      }
      if (uri[1] == "/") {
        return "${protocol()}:$uri";
      }
      return "";
      //return "${this.protocol()}://${location.host}${uri}";
    } catch (e) {
      print("ERRORE endpointURL $e - $endPoint $params");
      rethrow;
    }
  }

  void disconnect(Function callback, [int code, dynamic reason]){
    print("disconnect $code $reason");
    if(conn != null){
      if(code != null){ conn.close(code, reason ?? ""); } else { conn.close(); }
      conn = null;
    }
    if (callback != null) callback();
  }

  Future<Null> connect([Map<String, dynamic> params]) async{
    print("SOCKET connect - $params");
    if(params != null){
      print("passing params to connect is deprecated. Instead pass :params to the Socket constructor");
      this.params = params;
    }
    if(conn == null){
      try {
        conn = await WebSocket.connect(endPointURL());
        onConnOpen();
        print("oleeee");
        conn.listen(
                (dynamic event) =>  onConnMessage(event),
            onError: (dynamic error) => onError(error),
          onDone: () => log("transport", "connection done")
        );
        print("before rejoin $channels");
        channels.forEach( (String key, PhoenixChannel channel) {
          print("rejoin channel $key");
          channel.rejoin();
        });
        print("after rejoin $channels");
      } catch (exception) {
        print("ERRORE connect $exception");
        onConnError(exception);
      }
      //this.conn.onclose   = (event) => this.onConnClose(event);
    } else {
      print("SOCKET connect: conn is not null: disconnecting for reconnecting");
      conn = null;
      await connect();
    }
  }

  void log(String kind, String msg, [dynamic data]){
    if(logger != null)
      logger(kind, msg, data);
  }

  // Registers callbacks for connection state change events
  //
  // Examples
  //
  //    socket.onError(function(error){ alert("An error occurred") })
  //
  void onOpen     (Function callback){ stateChangeCallbacks["open"].add(callback); }
  void onClose    (Function callback){ stateChangeCallbacks["close"].add(callback); }
  void onError    (Function callback){ stateChangeCallbacks["error"].add(callback); }
  void onMessage  (Function callback){ stateChangeCallbacks["message"].add(callback); }

  void onConnOpen(){
    log("transport", "connected to ${endPointURL()}");
    flushSendBuffer();
    reconnectTimer.reset();
    if(heartbeatTimer != null)
      heartbeatTimer.cancel();
    heartbeatTimer = new Timer.periodic(new Duration(milliseconds: heartbeatIntervalMs),
        (Timer t) => sendHeartbeat());
    stateChangeCallbacks["open"].forEach((dynamic callback) => callback() );
  }

  void onConnClose(dynamic event){
    log("transport", "close", event);
    triggerChanError();
    heartbeatTimer.cancel();
    reconnectTimer.scheduleTimeout();
    stateChangeCallbacks["close"].forEach( (dynamic callback) => callback(event));
  }

  void onConnError(dynamic error){
    log("transport", error);
    triggerChanError();
    stateChangeCallbacks["error"].forEach((dynamic callback) => callback(error) );
  }

  void triggerChanError(){
    channels.forEach( (String key, PhoenixChannel channel) => channel.trigger(ChannelEvents.error) );
  }

  String connectionState(){
    if(conn == null) return "closed";
    switch(conn.readyState) {
      case SocketStates.connecting:
        return "connecting";
      case SocketStates.open:
        return "open";
      case SocketStates.closing:
        return "closing";
      default:
        return "closed";
    }
  }

  bool isConnected(){ return connectionState() == "open"; }

  void remove(PhoenixChannel channel){
    channels.remove(channel.topic);
  }

  PhoenixChannel channel(String topic, [Map<String, dynamic> chanParams]){
    chanParams ??= <String, dynamic>{};
    final PhoenixChannel  chan = new PhoenixChannel(topic, chanParams, this);
    channels[topic] = chan;
    return chan;
  }

  void push(Map<String, dynamic> data){
    final Function callback = () {
      this.encode(data, (dynamic result) {
        //this.conn.send(result);
        log("push", "result $result");
        conn.add(result);
      });
    };
    log("push", "${data['topic']} ${data['event']} (${data['join_ref']}, ${data['ref']})", data['payload']);
    if(isConnected()){
      log("push", "is connected");
      callback();
    }
    else {
      log("push", "is not connected");
      sendBuffer.add(callback);
    }
  }

  String makeRef(){
    final int newRef = ref + 1;
    if(newRef == ref){ ref = 0; } else { ref = newRef; }

    return ref.toString();
  }

  void sendHeartbeat(){
    if(isConnected()){
      if(pendingHeartbeatRef != null){
        pendingHeartbeatRef = null;
        log("transport", "heartbeat timeout. Attempting to re-establish connection");
        conn.close(WS_CLOSE_NORMAL, "hearbeat timeout");
      } else {
        pendingHeartbeatRef = makeRef();
        push(<String, dynamic>{"topic": "phoenix", "event": "heartbeat",
          "payload": <String, dynamic>{}, "ref": pendingHeartbeatRef});
      }
    }
  }

  void flushSendBuffer(){
    if(isConnected() && sendBuffer.isNotEmpty){
      sendBuffer.forEach( (dynamic callback) => callback() );
      sendBuffer = <dynamic>[];
    }
  }

  void onConnMessage(String rawMessage){
    //print("SOCKET onConnMessage - $rawMessage");
    this.decode(rawMessage, (Map<dynamic, dynamic> msg) {
      final String topic = msg["topic"];
      final String event = msg["event"];
      final Map<String, dynamic> payload = msg["payload"];
      final String ref = msg["ref"];
      final String joinRef = msg.containsKey("join_ref") ? msg["join_ref"] : "";
      
      if(ref != null && ref == pendingHeartbeatRef){ pendingHeartbeatRef = null; }
      final String status = payload["status"] ?? "";
      final String refLog = "($ref)";
      log("receive", "$status $topic $event $refLog", payload);
      channels.forEach( (String key, PhoenixChannel channel) {
        if(channel.isMember(topic, event, payload, joinRef))
          channel.trigger(event, payload, ref, joinRef);
      });
      stateChangeCallbacks["message"].forEach( (dynamic callback) => callback(msg) );
    });
  }
}
