#!/bin/bash
# 日报工作台一键同步：扫描各自动化日报 -> 重建索引 -> 推送 GitHub Pages
#
# ⚠️ 两个关键约束（踩过坑，别改）：
#  1) Pages 绑定的是 gh-pages 分支，必须 main 和 gh-pages 一起推，只推 main 页面不会更新
#  2) 9 类日报全部公开（含源哥×XZ交叉日报、宏观地缘日报）—— 阿成 2026-10-08 决定解除限制
#
# 开关：把 PUBLIC_ALL 改成 no 即可把 cross / macro-geo 两类重新隔离到本地（不上网）
PUBLIC_ALL="yes"          # yes = 9 类全部公开；no = 只公开 7 类，另两类仅本地
set -e
cd "$(dirname "$0")"
PY="C:/Users/wangz/.workbuddy/binaries/python/versions/3.13.12/python.exe"
SCRIPT="C:/Users/wangz/WorkBuddy/2026-10-07-23-45-13/collect_reports.py"

# ---- 并发互斥锁 ----
# 8:30 那批自动化（美伊/铜原油/知识星球/宏观地缘）几乎同时结束，会各自触发本脚本，
# 多个 git 进程同时 push 会互相抢锁导致推送失败。用目录锁串行化：
#   - mkdir 是原子操作，谁先建成功谁获得执行权
#   - 等不到锁就直接退出（本次改动由下一个触发者补上，不丢）
#   - 锁超过 20 分钟视为上次异常退出留下的死锁，自动清理
LOCK=".sync.lock"
STALE=1200
if ! mkdir "$LOCK" 2>/dev/null; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  if [ "$AGE" -gt "$STALE" ]; then
    echo "清理死锁（已存在 ${AGE}s）"
    rm -rf "$LOCK" && mkdir "$LOCK"
  else
    echo "已有同步在执行，本次跳过（${AGE}s 前启动）"
    exit 0
  fi
fi
# 无论正常退出还是异常退出都释放锁
trap 'rm -rf "$LOCK"' EXIT INT TERM

echo "[1/4] 扫描日报目录..."
"$PY" "$SCRIPT"

echo "[2/4] 提取紧张度 + 按开关处理分类..."
PUBLIC_ALL="$PUBLIC_ALL" "$PY" - <<'PYEOF'
import json,re,os
def txt_of(p):
    h=open(p,encoding='utf-8',errors='ignore').read()
    t=re.sub(r'<[^>]+>',' ',re.sub(r'<(script|style).*?</\1>',' ',h,flags=re.S|re.I))
    return re.sub(r'\s+',' ',t)

public_all = os.environ.get('PUBLIC_ALL','yes').strip().lower()=='yes'
m=json.load(open('manifest.json',encoding='utf-8'))

# 提取美伊日报紧张度（正文3000字内形如 88 /100 的数字）
for it in m['items']:
    if it['key']!='us-iran': continue
    f=re.findall(r'(\d{1,3})\s*/\s*100', txt_of(it['url'])[:3000])
    it['tension']=int(f[0]) if f and 0<int(f[0])<=100 else None

if public_all:
    # 全部公开：去掉内部标记，避免泄露本地路径
    for it in m['items']:
        it.pop('localPath',None)
        it.pop('sensitive',None)
    for s in m['sources']:
        s.pop('sensitive',None)
    json.dump(m,open('manifest.json','w',encoding='utf-8'),ensure_ascii=False,indent=1)
    raw=open('manifest.json',encoding='utf-8').read()
    assert 'localPath' not in raw, 'manifest.json 含本地路径，中止！'
    print(f"  公开 {len(m['items'])} 篇 / {len(m['sources'])} 类（全部公开模式）")
else:
    # 隔离模式：这两类仅本地保留
    pub_i=[i for i in m['items'] if not i.get('sensitive')]
    pub_s=[s for s in m['sources'] if not s.get('sensitive')]
    loc={'items':[i for i in m['items'] if i.get('sensitive')],
         'note':'隔离模式：这两类仅本地保留，不发布外网'}
    json.dump({'sources':pub_s,'items':pub_i},
              open('manifest.json','w',encoding='utf-8'),ensure_ascii=False,indent=1)
    os.makedirs('../daily-hub-private',exist_ok=True)
    json.dump(loc,open('../daily-hub-private/manifest.local-only.json','w',encoding='utf-8'),
              ensure_ascii=False,indent=1)
    raw=open('manifest.json',encoding='utf-8').read()
    assert 'localPath' not in raw, 'manifest.json 含本地路径，中止！'
    assert '"sensitive": true' not in raw, 'manifest.json 仍含敏感条目，中止！'
    print(f"  公开 {len(pub_i)} 篇 / {len(pub_s)} 类；隔离 {len(loc['items'])} 篇（仅本地）")

ui=[i for i in m['items'] if i['key']=='us-iran']
print(f"  紧张度 {sum(1 for i in ui if i.get('tension'))}/{len(ui)} 篇")
PYEOF

echo "[3/4] 校验索引与文件一致..."
"$PY" - <<'CHKEOF'
import json,os,sys
m=json.load(open('manifest.json',encoding='utf-8'))
its=m['items']
miss=[i['url'] for i in its if i.get('url') and not os.path.exists(i['url'])]
keep={os.path.normpath(i['url']) for i in its if i.get('url')}
extra=0
for root,_,files in os.walk('reports'):
    for fn in files:
        if fn.endswith('.html') and os.path.normpath(os.path.join(root,fn)) not in keep:
            extra+=1
if miss or extra:
    print(f'  ⚠ 缺失 {len(miss)} 份 / 未收录残留 {extra} 份，移入_orphan 隔离...')
    os.makedirs('_orphan',exist_ok=True)
    for root,_,files in os.walk('reports'):
        for fn in files:
            if not fn.endswith('.html'): continue
            p=os.path.normpath(os.path.join(root,fn))
            if p in keep: continue
            try: os.replace(p, os.path.join('_orphan', os.path.basename(root)+'_'+fn))
            except OSError: pass
    miss2=[i['url'] for i in its if i.get('url') and not os.path.exists(i['url'])]
    if miss2:
        print(f'  ✗ 仍有{len(miss2)} 份缺失：{miss2[:3]}')
        sys.exit(1)
    print(f'  ✓ 已隔离 {extra} 份，现一致（{len(its)} 份）')
else:
    print(f'  ✓ 一致（{len(its)} 份全部就位，无残留）')
CHKEOF

echo "[4/4] 提交并推送（main + gh-pages 双分支）..."
git add -A
if git diff --cached --quiet; then
  echo "  无新日报，跳过推送。"
  exit 0
fi
git -c user.name="wanghahaniu" -c user.email="wanghahaniu@users.noreply.github.com" \
    commit -q -m "日报更新 $(date +%Y-%m-%d)"

# 网络抖动或 GitHub 快进合并报500 时重试；用 --force 让远端直接重建引用（实测可绕过 500）
push_retry() {
  local refspec="$1" i out
  for i in 1 2 3; do
    if out=$(git push --force origin "${refspec}" 2>&1); then return 0; fi
    echo "    第${i}次失败：$(echo "$out" | grep -iE 'error|rejected|Internal Server' | head -1)"
    sleep 8
  done
  return 1
}
push_retry "main"          && echo "  ✓ main 已推送" || echo "  ⚠️ main 推送失败，请重跑"
push_retry "main:gh-pages" && echo "  ✓ gh-pages 已推送（Pages 靠它更新）" || echo "  ⚠️ gh-pages 推送失败，页面不会更新，请重跑"

echo "  构建约需 2-4 分钟，之后刷新 https://wanghahaniu.github.io/daily-hub/"