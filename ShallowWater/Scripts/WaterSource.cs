using System.Collections;
using UnityEngine;

namespace WaterSimulation
{
    public enum WaterSourceType
    {
        AddWaterOnce,
        AddWaterUpdate
    }
    public class WaterSource : MonoBehaviour
    {
        [Tooltip("The type of water source.")]
        public WaterSourceType waterSourceType = WaterSourceType.AddWaterOnce;
        WaterSourceType waterSourceType_old;
        public Material materialTransparent;
        public Material materialOpaque;
        [Tooltip("The rate of water injection in units per second.")]
        public float injectionRate = 0.1f;

        [Tooltip("The radius of the injection area in world units.")]
        public float radius = 1.0f;
        [Tooltip("Whether to add water to the simulation.")]
        public bool AddWater = false;
        bool isRegister = false;


        void OnEnable()
        {            
            this.gameObject.layer = LayerMask.NameToLayer("Water");            
        }
        IEnumerator AddWaterCoroutine()
        {
            this.gameObject.layer = LayerMask.NameToLayer("Default");            
            this.GetComponent<Renderer>().material = materialOpaque;
            yield return null; 
            this.gameObject.layer = LayerMask.NameToLayer("Water");
            this.GetComponent<Renderer>().material = materialTransparent;
        }

        void Update()
        {
            if (waterSourceType == WaterSourceType.AddWaterOnce)
            {
                if (waterSourceType_old != waterSourceType && isRegister)
                {
                    waterSourceType_old = waterSourceType;
                    isRegister = false;
                    ShallowWaterGPU.Instance.UnregisterWaterSource(this);
                }
            }
            if (AddWater && waterSourceType == WaterSourceType.AddWaterOnce)
            {
                isRegister = false;
                AddWater = false;
                ShallowWaterGPU.Instance.UnregisterWaterSource(this);                
                StartCoroutine(AddWaterCoroutine());
            }
            if (ShallowWaterGPU.Instance != null && waterSourceType == WaterSourceType.AddWaterUpdate && !isRegister)
            {
                this.GetComponent<Renderer>().material = materialTransparent;
                ShallowWaterGPU.Instance.RegisterWaterSource(this);
                isRegister = true;                
            }            
            waterSourceType_old = waterSourceType;
        }
        void OnDisable()
        {
            if (ShallowWaterGPU.Instance != null && waterSourceType == WaterSourceType.AddWaterUpdate)
            {
                ShallowWaterGPU.Instance.UnregisterWaterSource(this);
                isRegister = false;
            }
        }
    }
}
