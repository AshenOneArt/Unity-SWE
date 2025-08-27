using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[ExecuteInEditMode]
public class SetLight : MonoBehaviour
{
    // Start is called before the first frame update
    public Material material;
    public Material material2;
    void Start()
    {
        Light light = GetComponent<Light>();
    }

    // Update is called once per frame
    void Update()
    {
        material.SetVector("_CLightDir", transform.forward);
        material2.SetVector("_CLightDir", transform.forward);
    }
}
