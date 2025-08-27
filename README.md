# Shallow Water Simulation (Unity HDRP)

基于 **浅水方程 (Shallow Water Equations, SWE)** 的实时流体模拟实现，参考论文 [High Resolution Simulations of Surface Waves (Chentanez & Müller, 2010)](https://matthias-research.github.io/pages/publications/hfFluid.pdf)。  
本项目使用 Unity **HDRP + Compute Shader** 来模拟和渲染大规模水体效果。

---

## 背景

浅水方程 (SWE) 是其在二维高度场下的近似形式，假设水深远小于水平尺度，因而能大幅降低计算复杂度，同时保留波动传播、反射、溢流等关键现象。  
参考论文提出的方法在游戏和交互应用中应用广泛，能够实时渲染大面积海面、湖泊。

---

## 特性

- **基于高度场的浅水方程 (SWE)**  
  - 显式积分更新水深与速度  
  - 质量守恒的通量形式，保证长时间模拟稳定  

- **边界条件与外力**  
  - 固定边界（墙体、地形阻挡）  
  - 注水/外力 (交互体积)

- **渲染集成 (HDRP)**  
  - ComputeShader 驱动的 **水面高度场 → 法线贴图**  

- **实时性能**  
  - 完全 GPU 并行  
  - 适合大规模水域（湖泊、河流、海岸）
    
- **不保证无限稳定**  
  - 即使用的无限稳定的MacCormack回退半拉格朗日的平流方式，在不合理的dx，dt下，依然会导致不满足CFL条件，导致水面爆炸

---

## 使用方法

### 1. 克隆仓库
```bash
git clone https://github.com/yourname/ShallowWaterSim.git
```

### 2. 打开 Unity 工程
- 推荐 Unity 2022.3.20f1c1 或更新  
- 渲染管线：**HDRP**

### 3. 核心文件
- `ShallowWaterSim.compute` — Compute Shader 核心实现（基于 SWE）  
- `ShallowWater\Scripts\ShallowWaterGPU.cs` — C# — 调用核心
- `ShallowWater\Scripts\WaterSource.cs` — C# — 加水实现

### 4. 运行
- 运行后，在Scene场景选中injectWater，右侧带有注水功能脚本（WaterSource）
- 选择注水模式，AddWaterOnce是以当前模型为注水体积，单击Addwater开关完成一次注水（深度相机将对当前mesh进行一次Draw）
- 选择注水模式，AddWaterUpdate是持续注水，包含injectrate参数和radius参数来调节

---

## 方程与代码流程

### 控制方程
```
∂h/∂t + ∇·(h v) = 0
∂v/∂t = -g ∇η + a_ext
```

### 主循环
1. **速度平流**（MacCormack/半拉格朗日）  
2. **高度通量更新**（有限体积，守恒）  
3. **速度重力步**（-g∇η 更新）  
4. **边界** （反射，边界速度置0）
5. **外力 / 注入**（交互）  
6. **高斯模糊**（暂时不太适用）

### 高度通量更新公式
```
h_{i,j}^{n+1} = h_{i,j}^n - (Δt/Δx)(F_{i+1/2,j} - F_{i-1/2,j}) - (Δt/Δy)(G_{i,j+1/2} - G_{i,j-1/2})
F = h u,   G = h w
```

迎风取值：
```
F_{i+1/2,j} = h_{i,j} u_{i+1/2,j}, if u > 0
            = h_{i+1,j} u_{i+1/2,j}, else

G_{i,j+1/2} = h_{i,j} w_{i,j+1/2}, if w > 0
            = h_{i,j+1} w_{i,j+1/2}, else
```

## 参考

- Nuttapong Chentanez & Matthias Müller,  
  **High Resolution Simulations of Surface Waves**.  
  *Eurographics / ACM SIGGRAPH Symposium on Computer Animation, 2010*.  
  [PDF 链接](https://matthias-research.github.io/pages/publications/hfFluid.pdf)

- Bridson, R.  
  **Fluid Simulation for Computer Graphics**.  
  CRC Press, 2008.

---

## 效果预览

---

## License
MIT License.

