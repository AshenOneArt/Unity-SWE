using System;
using UnityEngine;
using System.Collections.Generic;


namespace WaterSimulation
{
    [RequireComponent(typeof(MeshFilter), typeof(MeshRenderer))]
    public class ShallowWaterGPU : MonoBehaviour
    {
        public static ShallowWaterGPU Instance { get; private set; }

        [Header("Grid Settings")]
        
        public int MeshVertexSize = 64;        

        [Header("Simulation Parameters")]
        public int SimulationSize = 512;
        public int loopCount = 1;
        public float dx = 0.5f;        
        public float dt = 0.01f;
        public float g = 9.81f;
        [Header("Simulation Parameters")]
        public int SceneDepthRTSize = 512;

        [Header("Initial Wave")]
        public float waveRadius = 20f;
        public float maxHeight = 2.0f;
        public float slopeHeight = 5.0f;

        [Header("Assets")]
        public ComputeShader computeShader;
        public Material waterMaterial;
        public Camera DepthCamera;

        private Mesh mesh;

        private RenderTexture H_ping, H_pong,H_Result; // R channel for Height
        private RenderTexture Velocity_ping, Velocity_pong; // RG channels for U and V velocity
        private RenderTexture Foam_ping, Foam_pong;
        private RenderTexture CameraSetRT;

        private int initKernel, advectKernel, divergenceKernel, pressureKernel, boundaryKernel, injectKernel;
        private int blurHorizontalKernel, blurVerticalKernel;
        private int calculateFoamKernel;
        
        // Water Sources Management
        private List<WaterSource> waterSources = new List<WaterSource>();
        private ComputeBuffer waterSourceBuffer;
        private WaterSourceData[] waterSourceData;
        
        struct WaterSourceData
        {
            public Vector2 position;
            public float radius;
            public float injectionRate;
        }

        public Vector2 WorldSize => new Vector2(SimulationSize * dx, SimulationSize * dx);
        public float PixelScale => MeshVertexSize;
        public RenderTexture WorldPositionRT;

        void Awake()
        {
            if (Instance != null && Instance != this)
            {
                Destroy(gameObject);
                return;
            }
            Instance = this;
        }

        void OnEnable()
        {
            mesh = new Mesh();
            GetComponent<MeshFilter>().mesh = mesh;
            GetComponent<MeshRenderer>().material = waterMaterial;

            CreateMesh();
            InitTextures();
            
            DepthCamera.targetTexture = CameraSetRT;
            
            initKernel = computeShader.FindKernel("InitWater");
            advectKernel = computeShader.FindKernel("Advect");
            divergenceKernel = computeShader.FindKernel("SolveDivergence");
            pressureKernel = computeShader.FindKernel("SolvePressure");
            boundaryKernel = computeShader.FindKernel("ApplyBoundary");
            injectKernel = computeShader.FindKernel("InjectWater");
            blurHorizontalKernel = computeShader.FindKernel("GaussianBlurHorizontal");
            blurVerticalKernel = computeShader.FindKernel("GaussianBlurVertical");
            calculateFoamKernel = computeShader.FindKernel("CalculateFoam");
            
            DispatchInitKernel();
            computeShader.SetInts("size", SimulationSize, SimulationSize);
            computeShader.SetFloat("dt", dt);
            computeShader.SetFloat("dx", dx);
            computeShader.SetFloat("g", g);
        }

        void CreateRenderTextureInner(ref RenderTexture rt, RenderTextureFormat format)
        {
            rt = new RenderTexture(SimulationSize, SimulationSize, 0, format);
            rt.enableRandomWrite = true;
            rt.Create();
        }
        void CreateRenderTexture(ref RenderTexture rt, RenderTextureFormat format, int width, int height)
        {
            rt = new RenderTexture(width, height, 0, format);
            rt.enableRandomWrite = true;
            rt.Create();
        }

        void InitTextures()
        {
            CreateRenderTextureInner(ref H_ping, RenderTextureFormat.RFloat);
            CreateRenderTextureInner(ref H_pong, RenderTextureFormat.RFloat);
            CreateRenderTextureInner(ref H_Result, RenderTextureFormat.RFloat);
            CreateRenderTextureInner(ref Velocity_ping, RenderTextureFormat.RGFloat);
            CreateRenderTextureInner(ref Velocity_pong, RenderTextureFormat.RGFloat);
            CreateRenderTextureInner(ref WorldPositionRT, RenderTextureFormat.RFloat);
            CreateRenderTextureInner(ref Foam_ping, RenderTextureFormat.RFloat);
            CreateRenderTextureInner(ref Foam_pong, RenderTextureFormat.RFloat);
            CreateRenderTexture(ref CameraSetRT, RenderTextureFormat.R8, SceneDepthRTSize, SceneDepthRTSize);
        }

        void DispatchInitKernel()
        {
            computeShader.SetInts("size", SimulationSize, SimulationSize);
            computeShader.SetFloats("center", SimulationSize / 2f, SimulationSize / 2f);
            computeShader.SetFloat("slopeHeight", slopeHeight);
            computeShader.SetFloat("waveRadius", waveRadius);
            computeShader.SetFloat("maxHeight", maxHeight);
            computeShader.SetTexture(initKernel, "B_read", WorldPositionRT);
            computeShader.SetTexture(initKernel, "Foam_write", Foam_ping);
            computeShader.SetTexture(initKernel, "H_write", H_ping);
            computeShader.SetTexture(initKernel, "Velocity_write", Velocity_ping);
            
            int threadGroupsX = (SimulationSize + 7) / 8;
            int threadGroupsY = (SimulationSize + 7) / 8;
            computeShader.Dispatch(initKernel, threadGroupsX, threadGroupsY, 1);
        }
        
        void Swap(ref RenderTexture ping, ref RenderTexture pong)
        {
            var temp = ping;
            ping = pong;
            pong = temp;
        }

        void Update()
        {
            if (WorldPositionRT == null) return;
            UpdateWaterSources();

            int threadGroupsX = (SimulationSize + 7) / 8;
            int threadGroupsY = (SimulationSize + 7) / 8;
            
            for (int i = 0; i < loopCount; i++)
            {
                computeShader.SetTexture(advectKernel, "H_read", H_ping);
                computeShader.SetTexture(advectKernel, "Velocity_read", Velocity_ping);
                computeShader.SetTexture(advectKernel, "B_read", WorldPositionRT);
                computeShader.SetTexture(advectKernel, "Foam_read", Foam_ping);                
                computeShader.SetTexture(advectKernel, "Velocity_write", Velocity_pong);
                computeShader.SetTexture(advectKernel, "H_write", H_pong);             
                computeShader.SetTexture(advectKernel, "Foam_write", Foam_pong);   
                computeShader.Dispatch(advectKernel, threadGroupsX, threadGroupsY, 1);
                Swap(ref Velocity_ping, ref Velocity_pong);
                Swap(ref H_ping, ref H_pong);
                Swap(ref Foam_ping, ref Foam_pong);

                computeShader.SetTexture(pressureKernel, "H_read", H_ping);
                computeShader.SetTexture(pressureKernel, "B_read", WorldPositionRT);
                computeShader.SetTexture(pressureKernel, "Velocity_read", Velocity_ping);
                computeShader.SetTexture(pressureKernel, "Velocity_write", Velocity_pong);
                computeShader.Dispatch(pressureKernel, threadGroupsX, threadGroupsY, 1);
                Swap(ref Velocity_ping, ref Velocity_pong);

                
                computeShader.SetTexture(divergenceKernel, "H_read", H_ping);
                computeShader.SetTexture(divergenceKernel, "Velocity_read", Velocity_ping);
                computeShader.SetTexture(divergenceKernel, "B_read", WorldPositionRT);
                computeShader.SetTexture(divergenceKernel, "H_write", H_pong);
                computeShader.SetTexture(divergenceKernel, "Foam_read", Foam_ping);
                computeShader.SetTexture(divergenceKernel, "Foam_write", Foam_pong);
                computeShader.Dispatch(divergenceKernel, threadGroupsX, threadGroupsY, 1);
                Swap(ref H_ping, ref H_pong);
                Swap(ref Foam_ping, ref Foam_pong);
                

                //Boundary Conditions
                computeShader.SetTexture(boundaryKernel, "H_read", H_ping);
                computeShader.SetTexture(boundaryKernel, "Velocity_read", Velocity_ping);
                computeShader.SetTexture(boundaryKernel, "H_write", H_pong);
                computeShader.SetTexture(boundaryKernel, "Velocity_write", Velocity_pong);
                computeShader.SetTexture(boundaryKernel, "B_read", WorldPositionRT);
                computeShader.Dispatch(boundaryKernel, threadGroupsX, threadGroupsY, 1);
                Swap(ref H_ping, ref H_pong);
                Swap(ref Velocity_ping, ref Velocity_pong);

                /* computeShader.SetTexture(calculateFoamKernel, "H_read", H_ping);
                computeShader.SetTexture(calculateFoamKernel, "B_read", WorldPositionRT);
                computeShader.SetTexture(calculateFoamKernel, "Foam_read", Foam_ping);
                computeShader.SetTexture(calculateFoamKernel, "Foam_write", Foam_pong);
                computeShader.Dispatch(calculateFoamKernel, threadGroupsX, threadGroupsY, 1);
                Swap(ref Foam_ping, ref Foam_pong); */
            }

            // --- Inject Water ---
            if (waterSources.Count > 0)
            {
                computeShader.SetInt("waterSourceCount", waterSources.Count);
                computeShader.SetBuffer(injectKernel, "waterSources", waterSourceBuffer);
                computeShader.SetTexture(injectKernel, "H_write", H_ping);
                computeShader.Dispatch(injectKernel, threadGroupsX, threadGroupsY, 1);
            }

            // 水平模糊通道：terrain -> terrainTemp
            computeShader.SetTexture(blurHorizontalKernel, "H_read", H_ping);
            computeShader.SetTexture(blurHorizontalKernel, "H_write", H_Result);            
            computeShader.SetInts("size", SimulationSize, SimulationSize);
            computeShader.Dispatch(blurHorizontalKernel, threadGroupsX, threadGroupsY, 1);
            
            // 垂直模糊通道：terrainTemp -> terrain
            computeShader.SetTexture(blurVerticalKernel, "H_read", H_Result);            
            computeShader.SetTexture(blurVerticalKernel, "H_write", H_Result);
            computeShader.SetInts("size", SimulationSize, SimulationSize);
            computeShader.Dispatch(blurVerticalKernel, threadGroupsX, threadGroupsY, 1);


            waterMaterial.SetTexture("_H_Blur", H_Result);
            waterMaterial.SetTexture("_H", H_ping);
            waterMaterial.SetTexture("_B", WorldPositionRT);
            waterMaterial.SetTexture("_Foam", Foam_ping);
            waterMaterial.SetTexture("_Velocity", Velocity_ping);    
            Shader.SetGlobalInt("_SimulationPixelSize", SimulationSize);
            Shader.SetGlobalInt("_SceneDepthRTSize", SceneDepthRTSize);
        }
        void LateUpdate()
        {
            if (DepthCamera != null && DepthCamera.isActiveAndEnabled)
            {
                DepthCamera.Render();
                DepthCamera.orthographicSize = (PixelScale) / 2;//深度拍摄区域得比模拟区域大
            }
        }

        void OnDisable()
        {
            H_ping?.Release();
            H_pong?.Release();
            H_Result?.Release();
            Velocity_ping?.Release();
            Velocity_pong?.Release();
            WorldPositionRT?.Release();
            CameraSetRT?.Release();
            waterSourceBuffer?.Release();
            waterSources.Clear();
            Foam_ping?.Release();
            Foam_pong?.Release();
            
        }

        void UpdateWaterSources()
        {                        
            if (waterSources.Count == 0)
            {
                if (waterSourceBuffer != null)
                {
                    waterSourceBuffer.Release();
                    waterSourceBuffer = null;
                }
                return;
            }

            if (waterSourceBuffer == null || waterSourceBuffer.count != waterSources.Count)
            {
                waterSourceBuffer?.Release();
                waterSourceBuffer = new ComputeBuffer(waterSources.Count, sizeof(float) * 4);
            }

            waterSourceData = new WaterSourceData[waterSources.Count];

            for (int i = 0; i < waterSources.Count; i++)
            {
                var source = waterSources[i];
                Vector3 worldPos = source.transform.position;
                
                float worldWidth = MeshVertexSize;
                float gridX = (worldPos.x + worldWidth * 0.5f) / worldWidth * (SimulationSize);
                float gridY = (worldPos.z + worldWidth * 0.5f) / worldWidth * (SimulationSize);

                waterSourceData[i] = new WaterSourceData
                {
                    position = new Vector2(gridX, gridY),
                    radius = source.radius,
                    injectionRate = source.injectionRate
                };
            }
            
            waterSourceBuffer.SetData(waterSourceData);
        }
        
        public void RegisterWaterSource(WaterSource source)
        {
            if (!waterSources.Contains(source))
            {
                waterSources.Add(source);
            }
        }

        public void UnregisterWaterSource(WaterSource source)
        {
            if (waterSources.Contains(source))
            {
                waterSources.Remove(source);
            }
        }

        void CreateMesh()
        {
            int vertexCount = (MeshVertexSize + 1) * (MeshVertexSize + 1);
            var vertices = new Vector3[vertexCount];
            var uvs = new Vector2[vertexCount];
            var triangles = new int[MeshVertexSize * MeshVertexSize * 6];

            float offsetX = (MeshVertexSize) / 2f;
            float offsetZ = (MeshVertexSize) / 2f;

            for (int i = 0, z = 0; z <= MeshVertexSize; z++)
            {
                for (int x = 0; x <= MeshVertexSize; x++, i++)
                {
                    vertices[i] = new Vector3(x - offsetX, 0, z - offsetZ);
                    uvs[i] = new Vector2((float)x / MeshVertexSize, (float)z / MeshVertexSize);
                }
            }

            for (int z = 0, vert = 0, tris = 0; z < MeshVertexSize; z++)
            {
                for (int x = 0; x < MeshVertexSize; x++)
                {
                    triangles[tris + 0] = vert + 0;
                    triangles[tris + 1] = vert + MeshVertexSize + 1;
                    triangles[tris + 2] = vert + 1;
                    triangles[tris + 3] = vert + 1;
                    triangles[tris + 4] = vert + MeshVertexSize + 1;
                    triangles[tris + 5] = vert + MeshVertexSize + 2;
                    vert++;
                    tris += 6;
                }
                vert++;
            }

            mesh.Clear();
            mesh.vertices = vertices;
            mesh.uv = uvs;
            mesh.triangles = triangles;
            mesh.RecalculateNormals();
            mesh.bounds = new Bounds(Vector3.zero, new Vector3(MeshVertexSize, maxHeight * 2, MeshVertexSize));
        }
    }
}