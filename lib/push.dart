import 'dart:async';

import './channel.dart';
import './timer.dart';

class Push {

  Channel channel;
  String event;
  Map payload;  
  Map receivedResp;
  var timeout;
  Timer timeoutTimer;
  List<Map> recHooks;
  bool sent;
  var ref;
  var refEvent;


  Push(channel, event, Map payload, timeout){
    this.channel      = channel;
    this.event        = event;
    this.payload      = payload ?? new Map();
    this.receivedResp = null;
    this.timeout      = timeout;
    this.timeoutTimer = null;
    this.recHooks     = [];
    this.sent         = false;
  }

  void resend(timeout){
    print("push resend");
    this.timeout = timeout;
    this.reset();
    this.send();
  }

  void send(){
    print("push send");
    if(!this.hasReceived("timeout")){
      this.startTimeout();
      this.sent = true;
      this.channel.socket.push({
        "topic": this.channel.topic,
        "event": this.event,
        "payload": this.payload,
        "ref": this.ref,
        "join_ref": this.channel.joinRef()
      });
    }
  }


  Push receive(status, callback){
    print("push receive $status ");
    if(this.hasReceived(status)){
      callback(this.receivedResp["response"]);
    }

    this.recHooks.add({"status": status, "callback": callback});
    return this;
  }


  // private

  void reset(){
    print("push reset");
    this.cancelRefEvent();
    this.ref          = null;
    this.refEvent     = null;
    this.receivedResp = null;
    this.sent         = false;
  }

  void matchReceive(payload){
    print("push matchReceive");
    var status = payload["status"];
    var response = payload["response"];
    //var ref = payload["ref"];
    this.recHooks.where((h) => h["status"] == status).toList()
                 .forEach( (h) => h["callback"](response));
  }

  void cancelRefEvent(){ 
    if(this.refEvent != null)
      this.channel.off(this.refEvent);
  }

  void cancelTimeout(){
    this.timeoutTimer.cancel();
    this.timeoutTimer = null;
  }

  void startTimeout(){
    print("push startTimeout");
    if(this.timeoutTimer != null)
      this.cancelTimeout();
    this.ref      = this.channel.socket.makeRef();
    this.refEvent = this.channel.replyEventName(this.ref);
    print("push startTimeout ${this.refEvent}");
    this.channel.on(this.refEvent, (Map payload, [ref, joinRef]) {
      print("channel on ${this.refEvent}  $payload");
      this.cancelRefEvent();
      this.cancelTimeout();
      this.receivedResp = payload;
      this.matchReceive(payload);
    });

    /*
    this.timeoutTimer = new PhoenixTimer(() {
      this.trigger("timeout", new Map());
    }, this.timeout);*/

    this.timeoutTimer = new Timer(new Duration(milliseconds: this.timeout), () {
      print("push timeoutTimer fired");
      this.trigger("timeout", new Map());
    });



    //this.timeoutTimer.scheduleTimeout();

  }

  bool hasReceived(status){
    print("push hasReceived ${this.receivedResp}");
    return this.receivedResp != null && this.receivedResp["status"] == status;
  }

  void trigger(status, Map response){
    print("push trigger");
    this.channel.trigger(this.refEvent, {"status": status, "response": response});
  }
}
