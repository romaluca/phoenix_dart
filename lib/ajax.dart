import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class Ajax {

  static Future<Null> request(method, endPoint, accept, body, timeout, ontimeout, callback) async{
    var httpClient = createHttpClient();
    try {
      var response = await httpClient.post(endPoint, body: body, headers: {
        "Content-Type": accept
      });
      Map r = JSON.decode(response.body);
      callback(r);
    } catch (ex) {
      callback(null);
    }
  }

  static String serialize(Map obj, [String parentKey]){
    List<String> queryStr = [];
    for(String key in obj.keys){ 
      if(obj.containsKey(key)){ 
        String paramKey = parentKey != null ? "$parentKey[$key]" : key;
        var paramVal = obj[key];
        if(paramVal is Map){
          queryStr.add(Ajax.serialize(paramVal, paramKey));
        } else {          
          queryStr.add(Uri.encodeComponent(paramKey) + "=" + Uri.encodeComponent(paramVal));
        }
      }
    }
    return queryStr.join("&");
  }

  static String appendParams(String url, Map params){
    if(params.length == 0){ return url; }

    var prefix = url.contains("?") ? "&" : "?";
    return "$url$prefix${Ajax.serialize(params)}";
  }
}


