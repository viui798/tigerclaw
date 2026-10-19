# 整句模型

把 TigerClaw 的 `sentence-fivegram-mobile.bin`（405,663,171 字节，TCSKNM03
Q8 v2）放在这里，`macos/build.sh` 就会自动打包进 App：

```
macos/resources/Models/sentence-fivegram-mobile.bin
```

SHA256:

```
756f6c92cf43ad6e8e3087ce66b711ac6ad0fc41e6f3fb82b3766e35ecab8681
```

也可以用环境变量指向任意位置：

```sh
export TIGERCLAW_SENTENCE_MODEL=/path/to/sentence-fivegram-mobile.bin
macos/build.sh
```

模型太大，不放进 Git 仓库。没有模型时仍可构建，只提供“虎码字词”；
“虎整句”会退回普通码表，`ctest` 会跳过整句断言。
