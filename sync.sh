#!/bin/bash
# 日报工作台一键同步：扫描五套自动化日报 -> 重建索引 -> 推送到 GitHub Pages
set -e
cd "$(dirname "$0")"
PY="C:/Users/wangz/.workbuddy/binaries/python/versions/3.13.12/python.exe"
SCRIPT="C:/Users/wangz/WorkBuddy/2026-10-07-23-45-13/collect_reports.py"

echo "[1/3] 扫描日报目录..."
"$PY" "$SCRIPT"

echo "[2/3] 补紧张度字段..."
"$PY" - <<'PYEOF'
import json,re
def txt_of(p):
    h=open(p,encoding='utf-8',errors='ignore').read()
    t=re.sub(r'<[^>]+>',' ',re.sub(r'<(script|style).*?</\1>',' ',h,flags=re.S|re.I))
    return re.sub(r'\s+',' ',t)

m=json.load(open('manifest.json',encoding='utf-8'))
# 提取美伊日报紧张度（正文 3000 字内形如 88 /100 的数字）
for it in m['items']:
    if it['key']!='us-iran': continue
    f=re.findall(r'(\d{1,3})\s*/\s*100', txt_of(it['url'])[:3000])
    it['tension']=int(f[0]) if f and 0<int(f[0])<=100 else None

json.dump(m,open('manifest.json','w',encoding='utf-8'),ensure_ascii=False,indent=1)
ui=[i for i in m['items'] if i['key']=='us-iran']
print(f"  共 {len(m['items'])} 篇 / {len(m['sources'])} 类（紧张度 {sum(1 for i in ui if i.get('tension'))}/{len(ui)} 篇）")
PYEOF

echo "[3/3] 提交并推送..."
git add -A
if git diff --cached --quiet; then
  echo "  无新日报，跳过推送。"
else
  git -c user.name="wanghahaniu" -c user.email="wanghahaniu@users.noreply.github.com" \
      commit -q -m "日报更新 $(date +%Y-%m-%d)"
  git push -q origin main
  echo "  已推送，等待 30秒后访问 https://wanghahaniu.github.io/daily-hub/"
fi
