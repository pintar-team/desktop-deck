import Foundation

public struct GridLayout {
    public let columns: Int, rows: Int
    public var capacity: Int { columns*rows }
    public init(count: Int,width: Double,height: Double,fixed: Int = 0) {
        if fixed>0 {
            columns=min(max(fixed,1),8); rows=max(1,(count+columns-1)/columns)
        } else {
            let count=max(1,count); var best=(1,count),area=0.0
            for c in 1...count {
                let r=(count+c-1)/c
                let cellW=max(1,width/Double(c))
                let cellH=max(1,height/Double(r))
                let fit=min(cellW/1.6,cellH)
                let candidate=fit*fit*1.6
                if candidate>area || (abs(candidate-area)<0.001 && width>=height && c>best.0) { area=candidate; best=(c,r) }
            }
            columns=best.0; rows=best.1
        }
    }
}
