import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
test('resource reads pass the original context through both native SDK gates',()=>{
  const android=readFileSync(new URL('../weapp_container_android/android/src/main/kotlin/dev/weapp/container/flutter/WeappContainerAndroidPlugin.kt',import.meta.url),'utf8');
  const ios=readFileSync(new URL('../weapp_container_ios/ios/Classes/WeappContainerIosPlugin.swift',import.meta.url),'utf8');
  assert.match(android,/"hostComponents"[^\n]*"hostApiResource"[^\n]*session\.hostServicesCommand\(call\.method, jsonObject\(args\.filterKeys \{ it != "id" \}\)\)/);
  assert.match(ios,/case "hostComponents"[^\n]*"hostApiResource"/);
  assert.match(ios,/session\.hostServicesCommand\(call\.method, try object\(args\.filter \{ \$0\.key != "id" \}\)\)/);
  assert.doesNotMatch(android,/"hostApiResource" ->/);
  assert.doesNotMatch(ios,/case "hostApiResource":/);
});
