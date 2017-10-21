import 'dart:async';
import 'dart:io';
import './utils.dart';
import './timer.dart';
import './ajax.dart';
import 'channel.dart';

class Socket {

  var stateChangeCallbacks;
  var channels;
  var sendBuffer;
  var ref;
  var timeout;  
  var defaultDecoder;
  var defaultEncoder;
  var encode;
  var decode;
  var heartbeatIntervalMs;
  var reconnectAfterMs;
  var logger;
  Map params;
  String endPoint;
  PhoenixTimer heartbeatTimer;
  var pendingHeartbeatRef;
  PhoenixTimer reconnectTimer;
  WebSocket conn;

  Socket(String endPoint, { timeout, heartbeatIntervalMs = 30000, reconnectAfterMs, logger, Map params}){
    this.stateChangeCallbacks = {"open": [], "close": [], "error": [], "message": []};
    this.channels             = [];
    this.sendBuffer           = [];
    this.ref                  = 0;
    this.timeout              = timeout ?? DEFAULT_TIMEOUT;  
    this.defaultEncoder       = Serializer.encode;
    this.defaultDecoder       = Serializer.decode;
    this.encode = encode ?? this.defaultEncoder;
    this.decode = decode ?? this.defaultDecoder;
    this.heartbeatIntervalMs  = heartbeatIntervalMs;
    this.reconnectAfterMs     = reconnectAfterMs ?? (tries){
      return [1000, 2000, 5000, 10000][tries - 1] ?? 10000;
    };
    this.logger               = logger ?? (){}; // noop
    this.params               = params ?? new Map();
    this.endPoint             = "${endPoint}/${TRANSPORTS.websocket}";
    this.heartbeatTimer       = null;
    this.pendingHeartbeatRef  = null;
    this.reconnectTimer       = new PhoenixTimer(() {
      this.disconnect(() => this.connect());
    }, this.reconnectAfterMs);
  }

  String protocol(){ return endPoint.contains("https") ? "wss" : "ws"; }

  String endPointURL(){
    String uri = Ajax.appendParams(
      Ajax.appendParams(this.endPoint, this.params), {"vsn": VSN});
    if(uri[0] != "/"){ return uri; }
    if(uri[1] == "/"){ return "${this.protocol()}:${uri}"; }
    return "";
    //return "${this.protocol()}://${location.host}${uri}";
  }

  void disconnect(callback, [code, reason]){
    if(this.conn != null){
      if(code != null){ this.conn.close(code, reason ?? ""); } else { this.conn.close(); }
      this.conn = null;
    }
    if (callback != null) callback();
  }

  Future connect([Map params]) async{
    if(params != null){
      print("passing params to connect is deprecated. Instead pass :params to the Socket constructor");
      this.params = params;
    }
    if(this.conn == null){
      try {
        this.conn = await WebSocket.connect(this.endPointURL());
        this.onConnOpen();
        this.conn.listen(
                (event) =>  this.onConnMessage(event),
            onError: (error) => this.onError(error)
        );
      } catch (exception) {
        this.onConnError(exception);
      }
      //    = () => this.onConnOpen();
      //this.conn.onerror   = ;
      //this.conn.onmessage = (event) => this.onConnMessage(event);
      //this.conn.onclose   = (event) => this.onConnClose(event);
    }
  }

  /**
   * Logs the message. Override `this.logger` for specialized logging. noops by default
   * @param {string} kind
   * @param {string} msg
   * @param {Object} data
   */
  void log(kind, msg, [data]){ this.logger(kind, msg, data); }

  // Registers callbacks for connection state change events
  //
  // Examples
  //
  //    socket.onError(function(error){ alert("An error occurred") })
  //
  void onOpen     (callback){ this.stateChangeCallbacks.open.push(callback); }
  void onClose    (callback){ this.stateChangeCallbacks.close.push(callback); }
  void onError    (callback){ this.stateChangeCallbacks.error.push(callback); }
  void onMessage  (callback){ this.stateChangeCallbacks.message.push(callback); }

  void onConnOpen(){
    this.log("transport", "connected to ${this.endPointURL()}");
    this.flushSendBuffer();
    this.reconnectTimer.reset();

    /*
    if(!this.conn.skipHeartbeat){
      this.heartbeatTimer.reset();
      this.heartbeatTimer = new PhoenixTimer(() => this.sendHeartbeat(), this.heartbeatIntervalMs);
    }

    this.stateChangeCallbacks.open.forEach( (callback) => callback() ); // ERRORREEEEE
    */
  }

  void onConnClose(event){
    this.log("transport", "close", event);
    this.triggerChanError();
    this.heartbeatTimer.reset();
    this.reconnectTimer.scheduleTimeout();
    this.stateChangeCallbacks.close.forEach( (callback) => callback(event));
  }

  void onConnError(error){
    this.log("transport", error);
    this.triggerChanError();
    this.stateChangeCallbacks.error.forEach((callback) => callback(error) );
  }

  void triggerChanError(){
    this.channels.forEach( (channel) => channel.trigger(CHANNEL_EVENTS.error) );
  }

  String connectionState(){
    if(this.conn == null) return "closed";
    switch(this.conn.readyState) {
      case SOCKET_STATES.connecting:
        return "connecting";
      case SOCKET_STATES.open:
        return "open";
      case SOCKET_STATES.closing:
        return "closing";
      default:
        return "closed";
    }
  }

  isConnected(){ return this.connectionState() == "open"; }

  remove(channel){
    this.channels = this.channels.filter((c) => c.joinRef() != channel.joinRef());
  }

  /**
   * Initiates a new channel for the given topic
   *
   * @param {string} topic
   * @param {Object} chanParams - Paramaters for the channel
   * @returns {Channel}
   */
  channel(topic, [chanParams]){
    chanParams ??= {};
    var chan = new Channel(topic, chanParams, this);
    this.channels.push(chan);
    return chan;
  }

  void push(Map data){

    var callback = () {
      this.encode(data, (result) {
        //this.conn.send(result);
        this.conn.add(result);
      });
    };
    this.log("push", "${data['topic']} ${data['event']} (${data['join_ref']}, ${data['ref']})", data['payload']);
    if(this.isConnected()){
      callback();
    }
    else {
      this.sendBuffer.push(callback);
    }
  }

  /**
   * Return the next message ref, accounting for overflows
   */
  makeRef(){
    var newRef = this.ref + 1;
    if(newRef == this.ref){ this.ref = 0; } else { this.ref = newRef; }

    return this.ref.toString();
  }

  sendHeartbeat(){ 
    if(this.isConnected()){ 
      if(this.pendingHeartbeatRef){
        this.pendingHeartbeatRef = null;
        this.log("transport", "heartbeat timeout. Attempting to re-establish connection");
        this.conn.close(WS_CLOSE_NORMAL, "hearbeat timeout");        
      } else {
        this.pendingHeartbeatRef = this.makeRef();
        this.push({"topic": "phoenix", "event": "heartbeat", "payload": {}, "ref": this.pendingHeartbeatRef});
      }
    }
  }

  flushSendBuffer(){
    if(this.isConnected() && this.sendBuffer.length > 0){
      this.sendBuffer.forEach( (callback) => callback() );
      this.sendBuffer = [];
    }
  }

  onConnMessage(rawMessage){
    this.decode(rawMessage.data, (Map msg) {
      var topic = msg["topic"];
      var event = msg["event"];
      var payload = msg["payload"];
      var ref = msg["ref"];
      var join_ref = msg["join_ref"];
      
      if(ref != null && ref == this.pendingHeartbeatRef){ this.pendingHeartbeatRef = null; }
      String status = payload.status ?? "";
      String refLog = "($ref)";
      this.log("receive", "$status $topic $event $refLog", payload);
      this.channels.filter( (channel) => channel.isMember(topic, event, payload, join_ref) )
                   .forEach( (channel) => channel.trigger(event, payload, ref, join_ref) );
      this.stateChangeCallbacks.message.forEach( (callback) => callback(msg) );
    });
  }
}
