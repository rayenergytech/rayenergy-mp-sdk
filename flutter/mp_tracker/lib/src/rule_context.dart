/// One context shared by collection and configuration requests. Values retain their original format.
class RuleContext {
  static const eventKeys = <String, String>{'country':'country_code','language':'device_language',
    'channel':'channel','adGroup':'adgroup','adCreative':'creative'};
  Map<String, String> _values = {};
  static String channel(Object? raw){if(raw==null)return 'organic';if(raw is! String)throw ArgumentError('channel must be a string');final value=raw.trim();if(value.isEmpty||['organic','web','ogannic','unknown','undefined','null','未知','未上报','自然量'].contains(value.toLowerCase()))return 'organic';if(value.length>64)throw ArgumentError('channel must be at most 64 characters');return value;}
  static String? _value(Object? raw) {
    if (raw == null) return null;
    if (raw is! String) throw ArgumentError('Rule context values must be strings or null');
    return raw.trim().isEmpty ? null : raw;
  }
  void patch(Map<String, Object?> fields) {
    final next = Map<String, String>.of(_values);
    for (final entry in fields.entries) {
      if (!eventKeys.containsKey(entry.key)) throw ArgumentError('Unsupported rule context field: ${entry.key}');
      final value = _value(entry.value);
      if (value == null) { next.remove(entry.key); } else { next[entry.key] = value; }
    }
    _values = next;
  }
  void replaceCommon(Map<String, Object?> fields) {
    final next = <String, String>{};
    for (final entry in eventKeys.entries) {
      if (fields.containsKey(entry.value)) {
        final value = _value(fields[entry.value]);
        if (value != null) next[entry.key] = value;
      }
    }
    _values = next;
  }
  Map<String, String> snapshot({String? deviceLanguage, Map<String,Object?> eventFields=const {}}) {
    final defaults=<String,String>{};
    for(final entry in eventKeys.entries) {
      if(eventFields.containsKey(entry.value)) {
        final value=_value(eventFields[entry.value]);
        if(value!=null) defaults[entry.key]=value;
      }
    }
    if(deviceLanguage!=null && deviceLanguage.trim().isNotEmpty) defaults['language']=deviceLanguage;
    final result={...defaults,..._values};result['channel']=channel(result['channel']);return result;
  }
}
