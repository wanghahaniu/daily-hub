#!/bin/bash
# 日报工作台一键同步：扫描各自动化日报 -> 重建索引 -> 剥离敏感分类 -> 推送 GitHub Pages
#
# ⚠️ 两个关键约束（踩过坑，别改）：
#  1) Pages 绑定的是 gh-pages 分支，必须 main 和 gh-pages 一起推，只推 main 页面不会更新
#  2) 源哥×XZ交叉日报 / 宏观地缘日报 来自源哥库与 XZ 库，自动化指令明令「禁止发布外网」，
#     必须剥离后再上线（本地清单存daily-hub-private/，绝不能提交）
set -e
cd "$(dirname "$0")"
PY="C:/Users/wangz/.workbuddy/binaries/python/versions/3.13.12/python.exe"
SCRIPT="C:/Users/wangz/WorkBuddy/2026-10-07-23-45-13/collect_reports.py"

echo "[1/4] 扫描日报目录..."
"$PY" "$SCRIPT"

echo "[2/4] 提取紧张度 + 剥离敏感分类..."
"$PY" - <<'PYEOF'
import json,re,os
def txt_of(p):
    h=open(p,encoding='utf-8',errors='ignore').read()
    t=re.sub(r'<[^>]+>',' ',re.sub(r'<(script|style).*?</\1>',' ',h,flags=re.S|re.I))
    return re.sub(r'\s+',' ',t)

m=json.load(open('manifest.json',encoding='utf-8'))

# 提取美伊日报紧张度（正文3000字内形如 88 /100 的数字）
for it in m['items']:
    if it['key']!='us-iran': continue
    f=re.findall(r'(\d{1,3})\s*/\s*100', txt_of(it['url'])[:3000])
    it['tension']=int(f[0]) if f and 0<int(f[0])<=100 else None

# 剥离敏感分类：不上网
pub_i=[i for i in m['items'] if not i.get('sensitive')]
pub_s=[s for s in m['sources'] if not s.get('sensitive')]
loc={'items':[i for i in m['items'] if i.get('sensitive')],
     'note':'源哥库/XZ库内容，自动化指令禁止发布外网，仅本地自用'}

json.dump({'sources':pub_s,'items':pub_i},
          open('manifest.json','w',encoding='utf-8'),ensure_ascii=False,indent=1)

os.makedirs('../daily-hub-private',exist_ok=True)
json.dump(loc,open('../daily-hub-private/manifest.local-only.json','w',encoding='utf-8'),
          ensure_ascii=False,indent=1)

# 兜底断言：敏感内容绝不进公开 manifest
# （sources 里的 "sensitive": false 是安全标记，允许存在；真正要拦的是 True / localPath / 敏感类名）
raw=open('manifest.json',encoding='utf-8').read()
assert '"sensitive": true' not in raw, 'manifest.json 仍含 sensitive:true（敏感条目），中止！'
assert 'localPath' not in raw, 'manifest.json 仍含 localPath（本地路径泄露），中止！'
assert '源哥' not in raw and '宏观地缘' not in raw, 'manifest.json 仍含敏感分类名，中止！'
assert not any(i.get('sensitive') for i in pub_i), '公开 manifest 混入敏感条目，中止！'

ui=[i for i in pub_i if i['key']=='us-iran']
print(f"  上线 {len(pub_i)} 篇 / {len(pub_s)} 类（紧张度 {sum(1 for i in ui if i.get('tension'))}/{len(ui)}）")
print(f"  本地私密 {len(loc['items'])} 篇 -> ../daily-hub-private/")
PYEOF

echo "[3/4] 校验 reports 目录无敏感文件..."
BAD=$(find reports -type f \( -iname "*源哥*" -o -iname "*macro-geo*" -o -iname "*交叉日报*" \) 2>/dev/null | head -3)
if [ -n "$BAD" ]; then
  echo "  ✗ reports/ 混入敏感文件，中止：$BAD"
  exit 1
fi
echo "  ✓ reports/ 干净（$(find reports -name '*.html' | wc -l) 份）"

echo "[4/4] 提交并推送（main + gh-pages 双分支）..."
git add -A
if git diff --cached --quiet; then
  echo "  无新日报，跳过推送。"
  exit 0
fi
git -c user.name="wanghahaniu" -c user.email="wanghahaniu@users.noreply.github.com" \
    commit -q -m "日报更新 $(date +%Y-%m-%d)"

# 网络抖动时重试，最多 3 次
push_retry() {
  for i in 1 2 3; do
    if git push origin "$@" 2>&1 | grep -qiE "error|fatal|failure"; then
      sleep 4
    else
      return 0
    fi
  done
  return 1
}
push_retry origin main          || echo "  ⚠️ main 推送失败，请重跑"
push_retry origin main:gh-pages --force || echo "  ⚠️ gh-pages 推送失败，页面不会更新，请重跑"

echo "  已推送，等30-60 秒后刷新 https://wanghahaniu.github.io/daily-hub/"