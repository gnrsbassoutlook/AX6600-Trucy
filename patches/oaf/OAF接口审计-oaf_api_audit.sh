#!/bin/sh
J=/tmp/c3.jar
rm -f $J
curl -s -c $J -o /dev/null -d 'luci_username=root&luci_password=<路由器密码>' http://127.0.0.1/cgi-bin/luci/
fail=0; total=0
while read u; do
  [ -z "$u" ] && continue
  total=$((total+1))
  code=$(curl -s -b $J -o /tmp/oo.txt -w '%{http_code}' "http://127.0.0.1/cgi-bin/luci/$u")
  if [ "$code" != "200" ]; then
    echo "FAIL $code  $u  ::  $(head -c 100 /tmp/oo.txt | tr -d '\n')"
    fail=$((fail+1))
  fi
done < /tmp/oaf_api_list.txt
echo "===== 共 $total 条，失败 $fail 条 ====="
