# Matter-Case

Matter の CASE プロトコルを Tamarin Prover で形式検証したモデルと結果。
鍵の漏洩条件をすべての組み合わせについて調べ、各セキュリティ性質が破れる安全境界を求めた。

SCIS 2027 発表「Matter CASEプロトコルにおける鍵漏洩条件の網羅的検証と安全境界の特定」のための成果物である。

## ディレクトリ構成

```
Matter-Case/
├── README.md
├── models/
│   ├── case.spthy               CASE 本体：安全境界、前方秘匿性、NOC の有効期限（時計が正確 / LKGT）
│   └── case_resumption.spthy    Session Resumption：再開鍵の境界と認証
├── boundary/                    漏洩条件の全組み合わせ（32 通り）の網羅
│   ├── case_i_secrecy_sk.spthy
│   ├── case_r_secrecy_sk.spthy
│   ├── case_i_secrecy_SS.spthy
│   ├── case_r_secrecy_SS.spthy
│   ├── case_auth_I_R.spthy
│   ├── case_auth_R_I.spthy
│   ├── case_destId_needs_ipk.spthy
│   ├── case_i_r_secrecy_Eph.spthy
│   ├── case_i_secrecy_sk_needs_ipk_and_Eph.spthy
│   └── case_r_secrecy_sk_needs_ipk_and_Eph.spthy  
├── scripts/
│   └── run.sh                models/case.spthy の全 lemma を実行（時計が正確 / LKGT）
└── results/
    ├── case_out.txt                 models/case.spthy の結果
    ├── case_resumption_out.txt      models/case_resumption.spthy の結果
    └── boundary/             網羅の結果（各 .spthy に 1 ファイル）
```

主張の根拠は `models/` の 2 ファイルである。`boundary/` は境界を見つけた過程と、別のモデルでの検算にあたる（同じ意味の lemma で証明のステップ数まで一致する）。

## 動作環境

| ソフトウェア | 版 |
|---|---|
| Tamarin Prover | 1.12.0 |
| Maude | 3.5.1 |

各 lemma は別プロセスで 1 本ずつ実行する。ファイル全体を一度に `--prove` すると、メモリが足りなくなることがある。最も重い lemma は 1 本あたり約 12 分だった（実行環境：AMD Ryzen AI 9 365 w/ Radeon 880M (2.00 GHz)・32GB）。

## モデル

### 鍵と漏洩

攻撃者は次の 5 種類の鍵を、いつでも漏らせる。

| 記号 | 鍵 | lemma で例外として扱う漏洩 |
|---|---|---|
| peerNOsK | 相手ノードの NOC 秘密鍵 | セッション確立（#i）より前の漏洩だけ |
| ownNOsK | 自分の NOC 秘密鍵 | #i より前の漏洩だけ |
| iEph | そのセッションの Initiator 一時秘密鍵 | すべての漏洩 |
| rEph | そのセッションの Responder 一時秘密鍵 | すべての漏洩 |
| IPK | そのファブリックの Identity Protection Key | すべての漏洩 |

### NOC の有効期限

期限は時刻ではなくイベントで表す。

- `NOC_Expired(n)`：n の NOC の notAfter が実時間で過ぎた。時点は攻撃者が選び、NOC ごとに 1 回だけ起きる。期限切れの後も秘密鍵は消えず、漏洩しうる。
- `UseValid(v, n)`：検証者 v が相手 n の NOC を受け入れた。期限の判定は検証する側が行う。
- 既定（時計が正確）：期限切れの後は、誰もその NOC を使わず、受け入れない。
- `-D=LKGT`（時計が遅れる）：検証者ごとの時計が、実際の期限切れより後で `KnowsExpired(v, n)` として追いつく。追いつく前は期限切れの NOC も受け入れる。時計が最後まで追いつかないトレースも含む。

### 省略したもの

`case_resumption.spthy` は CASE 本体を「正しく完了した」ことに抽象化しており、NOsK の漏洩は扱わない。

## 実行方法

### CASE 本体（`models/case.spthy`）

まとめて実行する場合：

```sh
cd scripts
./run.sh                 # 時計が正確 → LKGT の順に全 lemma
MODE=default ./run.sh    # 時計が正確なモデルだけ
MODE=lkgt    ./run.sh    # LKGT の有効期限の lemma だけ
```

1 本ずつ実行する場合：

```sh
# all-traces の lemma（boundary_*、forward_secrecy_* など）：制約なし
tamarin-prover --derivcheck-timeout=0 --prove=boundary_sk_I models/case.spthy

# 攻撃トレース（attack_*、case_finished）：探索制約つき
tamarin-prover --derivcheck-timeout=0 -D=SEARCH --prove=attack_sk_I_IPK_peerNOsK models/case.spthy

# 有効期限の exists-trace（expiry_executable、attack_expired_key_*）
tamarin-prover --derivcheck-timeout=0 -D=SEARCH_EXP --prove=expiry_executable models/case.spthy

# 時計が遅れるモデル
tamarin-prover --derivcheck-timeout=0 -D=LKGT -D=SEARCH_EXP --prove=attack_expired_key_R_I models/case.spthy
```

### Resumption（`models/case_resumption.spthy`）

```sh
tamarin-prover --prove models/case_resumption.spthy 
```

### 網羅（`boundary/`）

```sh
cd boundary
# OR 形・AND 形の lemma（all-traces）：制約なし
tamarin-prover --derivcheck-timeout=0 --prove=i_secrecy_sk_not_Leak_IPK case_i_secrecy_sk.spthy

# attack_*（exists-trace）：探索制約つき
tamarin-prover --derivcheck-timeout=0 -D=SEARCH --prove=attack_I_R_by_IPK_peerNOsK case_auth_I_R.spthy
```

lemma 名：

| 名前 | 意味 |
|---|---|
| `<性質>_not_Leak_<S>` | S の鍵がどれも漏れなければ性質が成り立つ |
| `<性質>_needs_<S>` | 性質が破れるときは S の鍵が全部漏れている |
| `attack_*` | 名前の鍵だけが漏れて性質が破れるトレースがある（exists-trace） |

## 探索制約と結果の読み方

`-D=SEARCH` と `-D=SEARCH_EXP` は、探索を終わらせるための制約である（ファブリック 1 つ、各役割 1 セッション、ノード 2 台。SEARCH は期限切れも禁止）。制約はトレースを取り除くだけなので、結果の有効性は次のとおり。

| lemma | 制約つきの結果 | 元のモデルについて言えるか |
|---|---|---|
| exists-trace | verified（トレースあり） | 言える |
| all-traces | falsified（反例あり） | 言える |
| all-traces | verified | 言えない |
| exists-trace | トレースなし | 言えない |
