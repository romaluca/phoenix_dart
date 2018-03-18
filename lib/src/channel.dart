import './push.dart';
import './socket.dart';
import './timer.dart';
import './utils.dart';




typedef void ResponseHandler(Map<String, dynamic> payload, [String ref, String joinRef]);

class PhoenixChannel {
  String state;
  String topic;
  Map<String, dynamic> params = <String, dynamic>{};
  PhoenixSocket socket;
  List<Map<String, dynamic>> bindings;
  int timeout;
  bool joinedOnce;
  Push joinPush;
  List<Push> pushBuffer;
  PhoenixTimer rejoinTimer;
  
  PhoenixChannel(this.topic, [this.params, this.socket]) {
    state       = ChannelStates.closed;
    bindings    = <Map<String, dynamic>>[];
    timeout     = socket.timeout;
    joinedOnce  = false;
    joinPush    = new Push(this, ChannelEvents.join, params, timeout);
    pushBuffer  = <Push>[];
    rejoinTimer  = new PhoenixTimer(
      () => rejoinUntilConnected(),
      socket.reconnectAfterMs
    );
    joinPush.receive("ok", ([Map<String, dynamic> response]) {
      state = ChannelStates.joined;
      rejoinTimer.reset();
      pushBuffer.forEach((Push pushEvent) => pushEvent.send() );
      pushBuffer = <Push>[];
    });
    onClose( ([Map<String, dynamic> response, String ref, String joinRef]) {
      rejoinTimer.reset();
      state = ChannelStates.closed;
      socket.remove(this);
    });
    onError( ([Map<String, dynamic> reason, String ref, String joinRef]) {
      if(!(isLeaving() || isClosed())){
        state = ChannelStates.errored;
        rejoinTimer.scheduleTimeout();
      }
    });
    joinPush.receive("timeout", () {
      if(isJoining()){
        socket.log("channel", "timeout $topic (${joinRef()})", joinPush.timeout);
        final Push leavePush = new Push(this, ChannelEvents.leave, <String, dynamic>{}, timeout);
        leavePush.send();
        state = ChannelStates.errored;
        joinPush.reset();
        rejoinTimer.scheduleTimeout();
      }
    });
    on(ChannelEvents.reply, ([ Map<String, dynamic> payload, String ref, String joinref]) {
      trigger(replyEventName(ref), payload);
    });
  }

  void rejoinUntilConnected(){
    rejoinTimer.scheduleTimeout();
    if(socket.isConnected()){
      rejoin();
    }
  }

  Push join([int _timeout]){
    _timeout ??= timeout;
    if(joinedOnce){
      throw("tried to join multiple times. 'join' can only be called a single time per channel instance");
    } else {
      joinedOnce = true;
      rejoin(_timeout);
      return joinPush;
    }
  }

  void onClose(ResponseHandler callback){
    on(ChannelEvents.close, callback);
  }

  void onError(ResponseHandler callback){
    on(ChannelEvents.error, callback);
  }

  void on(String event, ResponseHandler callback){
    bindings.add(<String, dynamic>{"event": event, "callback": callback});
  }

  void off(String event){ bindings = bindings.where( (Map<String, dynamic> bind) => bind["event"] != event ).toList(); }

  bool canPush(){ return socket.isConnected() && isJoined(); }

  Push push(String event, Map<String, dynamic> payload, [int timeout]){
    timeout ??= this.timeout;
    if(!joinedOnce){
      throw("tried to push '$event' to '$topic' before joining. Use channel.join() before pushing events");
    }
    final Push pushEvent = new Push(this, event, payload, timeout);
    if(canPush()){
      pushEvent.send();
    } else {
      pushEvent.startTimeout();
      pushBuffer.add(pushEvent);
    }

    return pushEvent;
  }


  Push leave([int timeout]){
    timeout ??= this.timeout;
    state = ChannelStates.leaving;
    final Function onClose = ([bool timeout = false]) {
      socket.log("channel", "leave $topic");
      trigger(ChannelEvents.close, <String, dynamic>{});
    };
    final Push leavePush = new Push(this, ChannelEvents.leave, <String, dynamic>{}, timeout);
    leavePush.receive("ok", (String e, [String ref, String joinRef]) => onClose())
    .receive("timeout", (String e, [String ref, String joinRef]) => onClose(true) );
    leavePush.send();
    if(!canPush()){ leavePush.trigger("ok", <String, dynamic>{}); }

    return leavePush;
  }


  Map<String, dynamic> onMessage(String event, Map<String, dynamic> payload, String ref){ return payload; }


  // private

  bool isMember(String topic, String event, Map<String, dynamic> payload, String joinRef){
    if(this.topic != topic){
      return false;
    }
    final bool isLifecycleEvent = kChannelLifecycleEvents.contains(event);

    if(joinRef != null && isLifecycleEvent && joinRef != this.joinRef()){
      socket.log("channel", "dropping outdated message", <String, dynamic>{"topic": topic, "event": event, "payload": payload, "joinRef": joinRef});
      return false;
    } else {
      return true;
    }
  }

  String joinRef(){ return joinPush.ref; }

  void sendJoin(int timeout){
    state = ChannelStates.joining;
    joinPush.resend(timeout);
  }

  void rejoin([int timeout]){
    timeout ??= this.timeout;

    if(!isLeaving())
      sendJoin(timeout);
  }

  void trigger(String event, [Map<String, dynamic> payload, String ref, String joinRef]){
    final Map<String, dynamic> handledPayload = onMessage(event, payload, ref);
    if(payload != null && handledPayload == null){ throw("channel onMessage callbacks must return the payload, modified or unmodified"); }
    bindings.where( (Map<String, dynamic> bind) => bind["event"] == event).map((Map<String, dynamic> bind) {

      bind["callback"](handledPayload, ref, joinRef ?? this.joinRef());
    }).toList();
  }

  String replyEventName(String ref){ return "chan_reply_$ref"; }

  bool isClosed() { return state == ChannelStates.closed; }
  bool isErrored(){ return state == ChannelStates.errored; }
  bool isJoined() { return state == ChannelStates.joined; }
  bool isJoining(){ return state == ChannelStates.joining; }
  bool isLeaving(){ return state == ChannelStates.leaving; }
}