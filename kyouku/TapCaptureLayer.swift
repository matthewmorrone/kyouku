//
//  TapCaptureLayer.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/21/25.
//


import SwiftUI
import UIKit
import Combine

struct TapCaptureLayer: UIViewRepresentable {
    let text: String
    let font: UIFont
    let onTapIndex: (String.Index?) -> Void

    func makeUIView(context: Context) -> TapCaptureView {
        let v = TapCaptureView()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.text = text
        v.font = font
        v.onTapIndex = onTapIndex
        return v
    }

    func updateUIView(_ uiView: TapCaptureView, context: Context) {
        uiView.text = text
        uiView.font = font
        uiView.onTapIndex = onTapIndex
        uiView.setNeedsLayout()
        uiView.setNeedsDisplay()
    }
}