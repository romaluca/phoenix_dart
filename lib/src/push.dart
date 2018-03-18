import 'dart:async';

import 'package:phoenix_dart/src/channel.dart';


class Push {

  PhoenixChannel channel;
  String event;
  Map<String, dynamic> payload = <String, dynamic>{};
  Map<String, dynamic> receivedResp;
  int timeout;
  Timer timeoutTimer;
  List<Map<String, dynamic>> recHooks;
  bool sent;
  String ref;
  String refEvent;


  Push(this.channel, this.event, this.payload, this.timeout){
    receivedResp = null;
    timeoutTimer = null;
    recHooks     = <Map<String, dynamic>>[];
    sent         = false;
  }

  void resend(int _timeout){
    timeout = _timeout;
    reset();
    send();
  }

  void send(){
    if(!hasReceived("timeout")){
      startTimeout();
      sent = true;
      channel.socket.push(<String, dynamic>{
        "topic": channel.topic,
        "event": event,
        "payload": payload,
        "ref": ref,
        "join_ref": channel.joinRef()
      });
    }
  }


  Push receive(String status, Function callback){
    if(hasReceived(status)){
      callback(receivedResp["response"]);
    }

    recHooks.add(<String, dynamic>{"status": status, "callback": callback});
    return this;
  }


  // private

  void reset(){
    cancelRefEvent();
    ref          = null;
    refEvent     = null;
    receivedResp = null;
    sent         = false;
  }

  void matchReceive(Map<String, dynamic> payload){
    final String status = payload["status"];
    final Map<String, dynamic> response = payload["response"];
    recHooks.where((dynamic h) => h["status"] == status).toList()
                 .forEach((dynamic h) {
      h["callback"](response);
    });
  }

  void cancelRefEvent(){ 
    if(refEvent != null)
      channel.off(refEvent);
  }

  void cancelTimeout(){
    timeoutTimer.cancel();
    timeoutTimer = null;
  }

  void startTimeout(){
    if(timeoutTimer != null)
      cancelTimeout();
    ref      = channel.socket.makeRef();
    refEvent = channel.replyEventName(ref);
    channel.on(refEvent, (Map<String, dynamic> payload, [String ref, String joinRef]) {
      cancelRefEvent();
      cancelTimeout();
      receivedResp = payload;
      matchReceive(payload);
    });

    

    timeoutTimer = new Timer(new Duration(milliseconds: timeout), () {
      trigger("timeout", <String, dynamic>{});
    });



    //this.timeoutTimer.scheduleTimeout();

  }

  bool hasReceived(String status){
    return receivedResp != null && receivedResp["status"] == status;
  }

  void trigger(String status, Map<String, dynamic> response){
    channel.trigger(refEvent, <String, dynamic>{"status": status, "response": response});
  }
}
