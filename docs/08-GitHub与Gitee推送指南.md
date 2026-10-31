# 08 推到 GitHub / Gitee（第一次就会遇到的所有坑）

> 目标：把 `E:\projects\linux-ops-platform` 变成一个正常的 GitHub 仓库，
> 让面试官点开链接能看到完整代码、README、CI 通过标记。

本文档按「你这台电脑的真实情况」写：**没有装 Git**、**没有 GitHub 账号密钥**、**GitHub 网页在国内经常打不开**。
下面的命令都已经在这台机器上验证过路径和参数。

---

## 0. 先解决 Git 没装的问题（已帮你装好）

我已经把绿色版 Git 放到 `E:\tools\PortableGit`，不需要管理员权限、不写注册表：

```powershell
E:\tools\PortableGit\cmd\git.exe --version
# git version 2.56.0.windows.4
```

想让它全局可用，把这个目录加进 PATH（当前用户级，不需要管理员）：

```powershell
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path","User") + ";E:\tools\PortableGit\cmd",
  "User")
```

**重开一个终端**后 `git --version` 就能用了。下面命令都按 `git` 已可用来写；
如果不想改 PATH，把 `git` 换成 `E:\tools\PortableGit\cmd\git.exe`。

---

## 1. 配身份（一次就够）

```bash
git config --global user.name "wudiliackerman-007"
git config --global user.email "你的GitHub注册邮箱@example.com"
git config --global init.defaultBranch main
git config --global core.quotepath false      # 中文文件名不显示成 \344\275...
git config --global core.autocrlf false       # 别乱改行尾，否则 shell 脚本一提交就变 CRLF
```

> `core.autocrlf false` 这条**一定要设**。Windows 默认会把 `\n` 改成 `\r\n`，
> 提交上去的 `*.sh` 到 Linux 上会报 `bad interpreter: /bin/bash^M`，
> 这是新手最常踩的坑，而且现象特别迷惑人。

---

## 2. 本地提交（已经在你的机器上做过一遍，这里是复现方法）

```bash
cd E:\projects\linux-ops-platform
git init
git add .
git status            # 先看一眼，确认没有把密钥/日志/ISO 加进去
git commit -m "feat: 一键部署的 Linux 运维平台（部署/监控/告警/发布回滚/巡检/备份）"
```

`.gitignore` 里已经排除了：

- `*.env`、`!*.env.example`（真实密码永远不进仓库）
- `*.pem`、`*.key`、`id_*`（私钥）
- `*.log`、`*.sql.gz`（日志和备份）
- `*.iso`、`*.vmdk`、`*.vmx`、`*.deb`、`*.tar.gz`（大文件）

> 想看「到底提交了什么」：`git ls-files | wc -l` 和 `git ls-files`。
> 这个项目应该是 **60 个左右的文本文件、200KB 上下**，超过 1MB 就说明混进了不该进的东西。

---

## 3. GitHub 上建仓库

1. 打开 https://github.com/new
2. Repository name：`linux-ops-platform`
3. **不要**勾选 "Add a README file" / ".gitignore" / "license"（本地已经有了，勾了会冲突）
4. 点 Create repository

然后拿到仓库地址，两种协议二选一：

| 协议 | 地址 | 适用 |
|------|------|------|
| SSH | `git@github.com:你的用户名/linux-ops-platform.git` | 推荐，配一次永久用 |
| HTTPS | `https://github.com/你的用户名/linux-ops-platform.git` | 每次 push 要输 token |

**国内网络注意**：`github.com:22` 经常被掐，但 `ssh.github.com:443` 是通的（本项目实测可达）。
所以 SSH 方式要在 `C:\Users\WuDi-Li\.ssh\config` 里加端口映射 —— **我已经帮你写好了**：

```
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519
```

> 直接 `ssh -T git@github.com` 走 22 端口可能一直卡住，
> 加上这段配置后用 `ssh -T git@github.com` 也走 443，就不会卡。
> 验证：`ssh -T git@github.com` 应返回 `Hi <用户名>! You've successfully authenticated`。

---

## 4. 把公钥贴到 GitHub（这一步必须你本人操作）

我已经在你的电脑上生成了专用密钥（不覆盖你以后可能有的其它 key）：

- 私钥：`C:\Users\WuDi-Li\.ssh\id_ed25519`（**不要发给任何人**，不进仓库）
- 公钥：`C:\Users\WuDi-Li\.ssh\id_ed25519.pub`

公钥内容（直接复制下面这一整行）：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMp3uMLUg/RcsBEUDz7VNtj1C2H3TZWy4ZKgD89td8+8 lihaipeng@linux-ops-platform
```

操作：GitHub → 右上角头像 → **Settings** → 左栏 **SSH and GPG keys** → **New SSH key**
→ Title 随便写（例如 `home-win11`）→ Key 粘贴上面一行 → **Add SSH key**。

验证：

```bash
ssh -T git@github.com
# Hi <你的用户名>! You've successfully authenticated, but GitHub does not provide shell access.
```

看到 `successfully authenticated` 就成功了。没成功的话看第 8 节排查。

---

## 5. 加远端并推送

```bash
cd E:\projects\linux-ops-platform

# 主远端：GitHub
git remote add origin git@github.com:你的用户名/linux-ops-platform.git

# 备远端：Gitee（国内面试官打开更快；不用可以不加）
git remote add gitee git@gitee.com:你的用户名/linux-ops-platform.git

git push -u origin main
```

Gitee 需要先在 https://gitee.com/projects/new 建同名空仓库，
再把**同一个公钥**贴到 Gitee：设置 → SSH 公钥 → 添加公钥。
然后：

```bash
git push -u gitee main        # 第一次
git push gitee main           # 以后
```

一条命令同时推两个：

```bash
git remote set-url --add --push origin git@github.com:你的用户名/linux-ops-platform.git
git remote set-url --add --push origin git@gitee.com:你的用户名/linux-ops-platform.git
git push origin main          # 现在会同时推 GitHub 和 Gitee
```

---

## 6. 提交前自检清单（面试官真的会点开看）

```bash
# 1) 有没有泄露密码/密钥
git grep -nEi "password|secret|token|BEGIN OPENSSH" -- ':!*.md' | head

# 2) 有没有大文件
git ls-files -s | awk '{print $4}' | xargs -I{} du -h {} 2>/dev/null | sort -hr | head

# 3) 脚本语法（有 bash 的机器上）
for f in $(git ls-files '*.sh'); do bash -n "$f" || echo "语法错误: $f"; done
```

CI（`.github/workflows/ci.yml`）会在你 push 之后自动跑：
`ruff` 检查 Python、`pytest` 跑单测、`bash -n` 检查所有 shell、`promtool` 校验告警规则。
**第一次 push 完去看 Actions 页面，全绿了再把链接写进简历** ——
简历上写"有 CI"但徽章是红的，比不写还糟。

---

## 7. 之后日常怎么用

```bash
git status                     # 看改了什么
git add -A && git commit -m "feat: 增加 xxx"
git push                       # 推 GitHub
git push gitee main            # 推 Gitee

git log --oneline --graph -15  # 看提交历史（面试前扫一眼，别被问懵）
```

在服务器上更新代码（部署脚本 `deploy/install_app.sh` 就是设计成从 Git 拉的）：

```bash
# 服务器上（Ubuntu）
cd /opt/ops-platform/repo
sudo -u ops git pull
sudo /opt/ops-platform/bin/release.sh        # 建新 release、切软链、健康检查、失败自动回滚
```

> 这就是「有 Git 才是可运维的」的含义：**发布的对象是 commit，不是一堆 scp 上去的文件**。
> 线上出问题时 `git log` 能回答"最近谁改了什么"，`release.sh --list` / `rollback.sh` 能回答"上一版是哪个"。

---

## 8. 常见报错对照表（都是真踩过的）

| 报错 | 原因 | 解决 |
|------|------|------|
| `ssh: connect to host github.com port 22: Connection timed out` | 22 端口被墙 | 用第 3 节的 `ssh.github.com:443` 配置 |
| `Permission denied (publickey)` | 公钥没贴 / 贴错 / 用错 key | `ssh -T -v git@github.com` 看用的哪个 key；重新贴公钥 |
| `Host key verification failed` | 第一次连，指纹没信任 | 输 `yes`；或 `ssh-keyscan ssh.github.com >> ~/.ssh/known_hosts` |
| `fatal: remote origin already exists` | 重复加远端 | `git remote set-url origin <新地址>` |
| `Updates were rejected because the remote contains work...` | GitHub 上建仓库时勾了 README | `git pull --rebase origin main` 后再 push |
| `error: src refspec main does not match any` | 还没 commit，或分支叫 master | `git branch -M main` 后再 push |
| `LF will be replaced by CRLF` 警告 | autocrlf 开了 | `git config --global core.autocrlf false` |
| push 很慢/卡在 `Writing objects` | 网络 | 换 HTTPS + 代理；或先推 Gitee 再让 GitHub 走 Gitee 镜像 |

---

## 9. 如果暂时连不上 GitHub，先推 Gitee 也行

面试官看的是「有没有工程化的痕迹」，不是「在哪个平台」。Gitee 一样能展示：

- 完整 commit 历史
- README 架构图
- CI（Gitee Go，或先不放徽章，口头说明本地跑过 `pytest`/`ruff`）

等网络条件好了再 `git remote add origin ...` 补推到 GitHub，
因为**同一个本地仓库可以有多个远端**，代码不用动。
