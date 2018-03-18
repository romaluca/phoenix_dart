import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class Ajax {

  static Future<Null> request(String method, String endPoint, String accept,
      Map<dynamic, dynamic> body, int timeout, Function ontimeout, Function callback) async{
    const JsonCodec json = const JsonCodec();
    try {
      final http.Response response = await http.post(endPoint, body: body, headers: <String, String>{
        "Content-Type": accept
      });
      final Map<String, dynamic> r = json.decode(response.body);
      callback(r);
    } catch (ex) {
      callback(null);
    }
  }

  static String serialize(Map<dynamic, dynamic> obj, [String parentKey]){
    final List<String> queryStr = <String>[];
    for(String key in obj.keys){ 
      if(obj.containsKey(key)){ 
        final String paramKey = parentKey != null ? "$parentKey[$key]" : key;
        final dynamic paramVal = obj[key];
        if(paramVal is Map){
          queryStr.add(Ajax.serialize(paramVal, paramKey));
        } else {          
          queryStr.add(Uri.encodeComponent(paramKey) + "=" + Uri.encodeComponent(paramVal));
        }
      }
    }
    return queryStr.join("&");
  }

  static String appendParams(String url, Map<String, dynamic> params){
    if(params.isEmpty){ return url; }

    final String prefix = url.contains("?") ? "&" : "?";
    return "$url$prefix${Ajax.serialize(params)}";
  }
}


