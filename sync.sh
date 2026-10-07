#!/bin/bash
# 日报工作台一键同步：扫描五套自动化日报 -> 重建索引 -> 推送到 GitHub Pages
set -e
cd "$(dirname "$0")"
PY="C:/Users/wangz/.workbuddy/binaries/python/versions/3.13.12/python.exe"
SCRIPT="C:/Users/wangz/WorkBuddy/2026-10-07-23-45-13/collect_reports.py"

echo "[1/3] 扫描日报目录..."
"$PY" "$SCRIPT"

echo "[2/3] 剥离敏感分类（源哥库/XZ库内容不外传）..."
"$PY" - <<'PYEOF'
import json,re,sys
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

pub_i=[i for i in m['items'] if not i.get('sensitive')]
pub_s=[s for s in m['sources'] if not s.get('sensitive')]
loc={'items':[i for i in m['items'] if i.get('sensitive')],
     'note':'源哥库/XZ库内容，禁止发布外网，仅本地自用'}
json.dump({'sources':pub_s,'items':pub_i},open('manifest.json','w',encoding='utf-8'),ensure_ascii=False,indent=1)
import os
os.makedirs('../daily-hub-private',exist_ok=True)
json.dump(loc,open('../daily-hub-private/manifest.local-only.json','w',encoding='utf-8'),ensure_ascii=False,indent=1)
ui=[i for i in pub_i if i['key']=='us-iran']
print(f"  公开 {len(pub_i)} 篇（含紧张度 {sum(1 for i in ui if i.get('tension'))}/{len(ui)} 篇）/ 本地私密 {len(loc['items'])} 篇")
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
