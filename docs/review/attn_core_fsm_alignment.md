# attn_core FSM 设计对齐意见

> 审阅对象：design_attn_core_fsm.md、mod_info_attn_core_fsm.md (同学提供)
> 审阅人：invoker-pray (HW 计算核心负责人)
> 日期：2026-07-09

## 1. 当前实现现状

attn_core.sv v2.0 已完成，关键设计决策：

| 决策 | 理由 |
|------|------|
| ST_LOAD_KV 全量 K/V URAM 预加载 | KV260 URAM 512KB 够用，消除 DDR 128× 重读 |
| ST_QK_DOT + ST_AV_DOT 分离 | MAC 256 DSP 分时复用 Phase A/B |
| 脉冲式 handshake | 已验证，低延迟 |
| Counter 更新合并在退出路径 | 减少无谓 cycle |

## 2. 文档需修改项

### 2.1 路径对齐 (P0)
| 文档路径 | 实际路径 |
|----------|----------|
| src/rtl/core/attn_core.sv | hw/rtl/core/attn_core.sv |
| src/rtl/pkg/attn_pkg.sv | hw/rtl/pkg/attn_pkg.sv |
| docs/spec/interfaces.md | docs/code_organization.html §8 |
| docs/spec/model.md | python_godel/attention_golden.py |
| D:/projects/LARA/ | 删除，统一为项目根相对路径 |

### 2.2 FSM 状态对齐 (P1)
文档 13 概念态 vs 实现 10 态。保留的架构差异已冻结：
- K/V 全量预加载 (ST_LOAD_KV) — 保留
- Phase A/B 分离 (ST_QK_DOT + ST_AV_DOT) — 保留，MAC 复用需要
- Counter 合并 — 保留，节省 cycle
- 脉冲握手 — 保留，已验证

### 2.3 模块边界
| 功能 | 位置 | 负责人 |
|------|------|--------|
| QKV projection | sw/host_attention.py (host) | SW |
| RoPE | hw/rtl/core/rope_engine.sv + sw/host_attention.py | HW+SW |
| RMSNorm | sw/host_attention.py (host) | SW |

### 2.4 采纳的配置项 (已实现)
| 配置项 | 状态 |
|--------|:---:|
| cfg_q_pos_base / cfg_kv_pos_base | ✅ v2.0 |
| cfg_causal 可配置 | ✅ v2.0 |
| start_ready 握手 | ✅ v2.0 |
| active_q_rows / active_kv_cols | ✅ v2.0 |
| ST_ERROR + 配置校验 | ✅ v2.0 |
| sticky done / error | ✅ v2.0 |

不采纳：
- cfg_seq_q/kv 分离 → prefill 模式 Q=KV 同长
- cfg_q_head_base/count → Phase 1 遍历全部 32 heads
- soft_reset → rst_n 覆盖
- valid/ready+done command 协议 → 脉冲已验证

### 2.5 文档合并
两文档重叠 >80%，建议合并为 docs/design/attn_core_fsm.md，删除 mod_info。

## 3. 已实现的关键功能

### 3.1 K/V 全量 URAM 预加载
ST_LOAD_KV 一次性加载全部 K/V 到 URAM。L=512 时 256KB per head，KV260 URAM 完全够。
DDR 只需 1 次传输 (vs 无 cache 需要 N_KV_tiles 次)。
同学的外围驱动只需在 ST_LOAD_KV 期间做一次 DMA。

### 3.2 attn_core v2.0 新增端口
- cfg_q_pos_base/kv_pos_base (16b) — 绝对位置基准
- cfg_causal (1b) — causal mask 使能
- start_ready (1b) — valid/ready 握手
- q_tile_start/kv_tile_start (16b output) — 给 softmax_engine 做 mask
- active_q_rows (5b) / active_kv_cols (7b) — partial tile 范围
- error (1b sticky) — 配置校验失败

### 3.3 ST_ERROR 校验
seq_len==0, seq_len>MAX, position+len 越界 → ST_ERROR (sticky error=1, 等下次 start 或 reset)

### 3.4 Partial Tile
active_q_rows = (last_tile && seq_len%TILE_Q!=0) ? seq_len%TILE_Q : TILE_Q
active_kv_cols 同理

### 3.5 Causal Mask 位置
q_pos_start = cfg_q_pos_base + q_tile_idx × TILE_Q
kv_pos_start = cfg_kv_pos_base + kv_tile_idx × TILE_KV
传递给 softmax_engine: mask when kv_pos > q_pos

## 4. 下一步对齐动作
| 优先级 | 动作 | 负责人 |
|:---:|------|--------|
| P0 | 文档路径统一 | FSM/外围驱动 |
| P1 | FSM 状态命名对齐 | FSM/外围驱动 |
| P1 | 两文档合并 | FSM/外围驱动 |
| P2 | 确认外围驱动兼容 v2.0 端口 | 双方 |

## 5. 两文档质量评价
| 维度 | 评价 |
|------|------|
| 架构思想 | ⭐⭐⭐⭐⭐ 统一 command 协议、位置显式、错误处理完善 |
| 可维护性 | ⭐⭐⭐ 路径不一致、双文档重叠 |
| 与实现对齐度 | ⭐⭐ 需更新 |
| 关键贡献 | position base、ST_ERROR — 已全部采纳 |
