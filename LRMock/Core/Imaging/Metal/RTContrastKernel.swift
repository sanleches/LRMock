//
//  RTContrastKernel.swift
//  RawLight
//
//  Bridges the `rtContrast` Metal compute shader into a Core Image filter graph
//  using `CIImageProcessorKernel`. Core Image supplies input/output Metal
//  textures and a command buffer; we just encode the compute dispatch.
//
//  This is the pattern every future RawTherapee-derived kernel will follow:
//  write the math in `.metal`, wrap it in a small `CIImageProcessorKernel`, and
//  drop it into the pipeline — no change to the UI or the `RawPipeline` contract.
//

import CoreImage
import Metal

final class RTContrastKernel: CIImageProcessorKernel {

    /// Argument keys passed through `apply(...)`.
    enum Key {
        static let amount = "amount"   // Float, -1...1
        static let prot = "prot"       // Float, highlight/shadow protection
    }

    // Work in full float precision to match the curve math.
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func process(
        with inputs: [CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: CIImageProcessorOutput
    ) throws {
        guard
            let input = inputs?.first,
            let sourceTexture = input.metalTexture,
            let destinationTexture = output.metalTexture,
            let commandBuffer = output.metalCommandBuffer,
            let pipeline = MetalContext.shared.computePipeline(function: "rtContrast"),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw RawPipelineError.renderFailed
        }

        var amount = (arguments?[Key.amount] as? Float) ?? 0
        var prot = (arguments?[Key.prot] as? Float) ?? 1.0

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        encoder.setBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&prot, length: MemoryLayout<Float>.size, index: 1)

        // Standard 2D tiling using the pipeline's preferred widths.
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(
            width: (destinationTexture.width + w - 1) / w,
            height: (destinationTexture.height + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    /// Convenience that applies the contrast curve to a CIImage.
    static func apply(to image: CIImage, amount: Float, prot: Float = 1.0) -> CIImage {
        guard amount != 0 else { return image }
        let output = try? apply(
            withExtent: image.extent,
            inputs: [image],
            arguments: [Key.amount: amount, Key.prot: prot]
        )
        return output ?? image
    }
}
