import './utils.dart';
import './push.dart';
import './timer.dart';
import './socket.dart';

class Channel {
  String state;
  var topic;
  Map params;
  Socket socket;
  List<Map> bindings;
  var timeout;
  var joinedOnce;
  Push joinPush;
  List pushBuffer;
  PhoenixTimer rejoinTimer;

  Channel(topic, [params, socket]) {
    this.state       = CHANNEL_STATES.closed;
    this.topic       = topic;
    this.params      = params ?? new Map();
    this.socket      = socket;
    this.bindings    = [];
    this.timeout     = this.socket.timeout;
    this.joinedOnce  = false;
    this.joinPush    = new Push(this, CHANNEL_EVENTS.join, this.params, this.timeout);
    this.pushBuffer  = [];
    this.rejoinTimer  = new PhoenixTimer(
      () => this.rejoinUntilConnected(),
      this.socket.reconnectAfterMs
    );
    this.joinPush.receive("ok", ([response]) {
      print("joinPush receive OK");
      this.state = CHANNEL_STATES.joined;
      this.rejoinTimer.reset();
      this.pushBuffer.forEach((pushEvent) => pushEvent.send() );
      this.pushBuffer = [];
    });
    this.onClose( ([response]) {
      this.rejoinTimer.reset();
      this.socket.log("channel", "close ${this.topic} ${this.joinRef()}");
      this.state = CHANNEL_STATES.closed;
      this.socket.remove(this);
    });
    this.onError( ([reason, ref, joinRef]) {
      if(!(this.isLeaving() || this.isClosed())){ 
        this.socket.log("channel", "error ${this.topic}", reason);
        this.state = CHANNEL_STATES.errored;
        this.rejoinTimer.scheduleTimeout();
      }
    });
    this.joinPush.receive("timeout", () {
      print("joinPush receive timeout");
      if(this.isJoining()){
        this.socket.log("channel", "timeout ${this.topic} (${this.joinRef()})", this.joinPush.timeout);
        var leavePush = new Push(this, CHANNEL_EVENTS.leave, new Map(), this.timeout);
        leavePush.send();
        this.state = CHANNEL_STATES.errored;
        this.joinPush.reset();
        this.rejoinTimer.scheduleTimeout();
      }
    });
    this.on(CHANNEL_EVENTS.reply, ([ Map payload, ref, joinref]) {
      print("channel receive reply");
      this.trigger(this.replyEventName(ref), payload);
    });
  }

  rejoinUntilConnected(){
    this.rejoinTimer.scheduleTimeout();
    if(this.socket.isConnected()){
      this.rejoin();
    }
  }

  Push join([timeout]){
    timeout ??= this.timeout;
    if(this.joinedOnce){
      throw("tried to join multiple times. 'join' can only be called a single time per channel instance");
    } else {
      this.joinedOnce = true;
      this.rejoin(timeout);
      return this.joinPush;
    }
  }

  void onClose(callback){
    print("channel close");
    this.on(CHANNEL_EVENTS.close, callback);
  }

  void onError(callback){
    print("channel error");
    this.on(CHANNEL_EVENTS.error, ([reason, ref, joinRef]) => callback(reason) );
  }

  void on(event, callback){
    print("channel on $event");
    this.bindings.add({"event": event, "callback": callback});
  }

  void off(event){ this.bindings = this.bindings.where( (bind) => bind["event"] != event ).toList(); }

  bool canPush(){ return this.socket.isConnected() && this.isJoined(); }

  Push push(event, payload, [timeout]){
    timeout ??= this.timeout;
    if(!this.joinedOnce){
      throw("tried to push '$event' to '${this.topic}' before joining. Use channel.join() before pushing events");
    }
    Push pushEvent = new Push(this, event, payload, timeout);
    if(this.canPush()){
      print("canPush");
      pushEvent.send();
    } else {
      print("can't push isConnected: ${this.socket.isConnected()} isJoined: ${this.isJoined()} state: ${this.state}");
      pushEvent.startTimeout();
      this.pushBuffer.add(pushEvent);
    }

    return pushEvent;
  }


  Push leave([timeout]){
    timeout ??= this.timeout;
    this.state = CHANNEL_STATES.leaving;
    var onClose = () {
      this.socket.log("channel", "leave ${this.topic}");
      this.trigger(CHANNEL_EVENTS.close, "leave");
    };
    Push leavePush = new Push(this, CHANNEL_EVENTS.leave, new Map(), timeout);
    leavePush.receive("ok", () => onClose() )
             .receive("timeout", () => onClose() );
    leavePush.send();
    if(!this.canPush()){ leavePush.trigger("ok", new Map()); }

    return leavePush;
  }


  Map onMessage(event, payload, ref){ return payload; }


  // private

  bool isMember(topic, event, payload, joinRef){
    if(this.topic != topic){
      print("isMember: false");
      return false;
    }
    var isLifecycleEvent = CHANNEL_LIFECYCLE_EVENTS.indexOf(event) >= 0;

    if(joinRef != null && isLifecycleEvent && joinRef != this.joinRef()){
      this.socket.log("channel", "dropping outdated message", {"topic": topic, "event": event, "payload": payload, "joinRef": joinRef});
      print("isMember: false");
      return false;
    } else {
      print("isMember: true");
      return true;
    }
  }

  joinRef(){ return this.joinPush.ref; }

  void sendJoin(timeout){
    print("sendJoin $timeout");
    this.state = CHANNEL_STATES.joining;
    this.joinPush.resend(timeout);
  }

  void rejoin([timeout]){
    print("reJoin");
    timeout ??= this.timeout;

    if(!this.isLeaving()) 
      this.sendJoin(timeout);
  }

  void trigger(event, [payload, ref, joinRef]){
    print("trigger $event $payload $ref $joinRef");
    Map handledPayload = this.onMessage(event, payload, ref);
    if(payload != null && handledPayload == null){ throw("channel onMessage callbacks must return the payload, modified or unmodified"); }
    print("trigger bindings: ${this.bindings.length}");
    this.bindings.where( (Map bind) => bind["event"] == event).map((Map bind) {
      print("trigger map bind $bind ${bind["callback"]}");
      bind["callback"](handledPayload, ref, joinRef ?? this.joinRef());
    }).toList();
  }

  String replyEventName(ref){ return "chan_reply_${ref}"; }

  bool isClosed() { return this.state == CHANNEL_STATES.closed; }
  bool isErrored(){ return this.state == CHANNEL_STATES.errored; }
  bool isJoined() { return this.state == CHANNEL_STATES.joined; }
  bool isJoining(){ return this.state == CHANNEL_STATES.joining; }
  bool isLeaving(){ return this.state == CHANNEL_STATES.leaving; }
}