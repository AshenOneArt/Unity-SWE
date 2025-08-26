using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.HighDefinition;
using System;
using WaterSimulation;


[Serializable, VolumeComponentMenu("Custom/Depth To World Position Pass")]
public sealed class DepthToWorldPositionPass : CustomPass
{
    private RenderTexture    targetTexture;
    public Camera           topDownCamera;
    public LayerMask        layerMask;

    Matrix4x4 customProjMatrix;
    public Material depth2HeightMat;
    
    // In your Setup method or constructor, create the material
    protected override void Execute(CustomPassContext ctx)
    {
        if (topDownCamera == null || depth2HeightMat == null)
            return;

        if (ShallowWaterGPU.Instance != null)
        {
            targetTexture = ShallowWaterGPU.Instance.WorldPositionRT;        
        }
        RTHandle sourceDepth = ctx.cameraDepthBuffer;
        depth2HeightMat.SetTexture("_InputDepthTexture", sourceDepth);
        CoreUtils.SetRenderTarget(ctx.cmd, targetTexture);
        ctx.cmd.DrawProcedural(Matrix4x4.identity, depth2HeightMat, 0, MeshTopology.Triangles, 3);    
    }

}
