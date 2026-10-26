import { useState } from 'react';
import { Upload, Database, Play, BarChart3 } from 'lucide-react';
import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

const mockComparisonData = [
  { bacteria: 'Lactobacillus', yourData: 65, publicData: 58 },
  { bacteria: 'Gardnerella', yourData: 12, publicData: 18 },
  { bacteria: 'Prevotella', yourData: 8, publicData: 10 },
  { bacteria: 'Atopobium', yourData: 6, publicData: 5 },
  { bacteria: 'Streptococcus', yourData: 5, publicData: 4 },
  { bacteria: 'Others', yourData: 4, publicData: 5 },
];

export function ComparePage() {
  const [processedFile, setProcessedFile] = useState('');
  const [publicDataset, setPublicDataset] = useState('');
  const [comparisonMetric, setComparisonMetric] = useState('abundance');
  const [outputGraph, setOutputGraph] = useState('bar');
  const [running, setRunning] = useState(false);
  const [showResults, setShowResults] = useState(false);

  const handleCompare = () => {
    setRunning(true);
    setShowResults(false);
    setTimeout(() => {
      setRunning(false);
      setShowResults(true);
    }, 2000);
  };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-gray-900">Compare Analysis</h1>
        <p className="text-gray-600">Compare your data against publicly available datasets</p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Input Panel */}
        <div className="lg:col-span-1 space-y-6">
          <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
            <div className="flex items-center gap-2 mb-6">
              <Upload className="w-5 h-5 text-gray-700" />
              <h2 className="text-gray-900">Data Input</h2>
            </div>

            <div className="space-y-5">
              {/* Processed Data Upload */}
              <div>
                <label className="block text-gray-700 mb-2">Your Processed Data</label>
                <div className="border-2 border-dashed border-gray-300 rounded-lg p-6 text-center hover:border-blue-400 transition-colors cursor-pointer">
                  <Upload className="w-8 h-8 text-gray-400 mx-auto mb-2" />
                  <p className="text-sm text-gray-600 mb-1">Click to upload or drag and drop</p>
                  <p className="text-xs text-gray-500">CSV, TSV, or BIOM format</p>
                </div>
                {processedFile && (
                  <p className="text-sm text-gray-700 mt-2">Uploaded: {processedFile}</p>
                )}
              </div>

              {/* Public Dataset Selection */}
              <div>
                <label className="block text-gray-700 mb-2">Public Dataset</label>
                <select
                  value={publicDataset}
                  onChange={(e) => setPublicDataset(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                >
                  <option value="">Select a dataset...</option>
                  <option value="hmp_vaginal">HMP - Vaginal Microbiome</option>
                  <option value="hmp_gut">HMP - Gut Microbiome</option>
                  <option value="hmp_oral">HMP - Oral Microbiome</option>
                  <option value="hmp_skin">HMP - Skin Microbiome</option>
                  <option value="mgnify_gut">MGnify - Human Gut</option>
                  <option value="curatedmeta">curatedMetagenomicData</option>
                </select>
                {publicDataset && (
                  <p className="text-xs text-gray-500 mt-2">
                    {publicDataset === 'hmp_vaginal' && '~500 samples from healthy women'}
                    {publicDataset === 'hmp_gut' && '~1,200 samples from diverse populations'}
                    {publicDataset === 'hmp_oral' && '~800 samples from oral cavity sites'}
                    {publicDataset === 'hmp_skin' && '~600 samples from skin microbiome'}
                  </p>
                )}
              </div>

              {/* Comparison Metric */}
              <div>
                <label className="block text-gray-700 mb-2">Comparison Metric</label>
                <select
                  value={comparisonMetric}
                  onChange={(e) => setComparisonMetric(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                >
                  <option value="abundance">Bacterial Abundance</option>
                  <option value="diversity">Alpha Diversity</option>
                  <option value="beta">Beta Diversity</option>
                  <option value="richness">Species Richness</option>
                </select>
              </div>

              {/* Output Graph Type */}
              <div>
                <label className="block text-gray-700 mb-2">Output Graph Type</label>
                <select
                  value={outputGraph}
                  onChange={(e) => setOutputGraph(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md text-gray-900"
                >
                  <option value="bar">Bar Chart</option>
                  <option value="stacked">Stacked Bar Chart</option>
                  <option value="heatmap">Heatmap</option>
                  <option value="scatter">Scatter Plot</option>
                  <option value="box">Box Plot</option>
                </select>
              </div>
            </div>

            <button
              onClick={handleCompare}
              disabled={running || !publicDataset}
              className="w-full mt-6 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-400 text-white px-4 py-3 rounded-md flex items-center justify-center gap-2 transition-colors"
            >
              {running ? (
                <>
                  <div className="w-5 h-5 border-2 border-white border-t-transparent rounded-full animate-spin" />
                  Comparing...
                </>
              ) : (
                <>
                  <Play className="w-5 h-5" />
                  Run Comparison
                </>
              )}
            </button>
          </div>

          {/* Info Panel */}
          <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
            <div className="flex items-start gap-2">
              <Database className="w-5 h-5 text-blue-600 mt-0.5" />
              <div>
                <h3 className="text-blue-900 mb-1">About Public Datasets</h3>
                <p className="text-sm text-blue-700">
                  Compare your sequencing results against curated public microbiome datasets from
                  the Human Microbiome Project and other sources.
                </p>
              </div>
            </div>
          </div>
        </div>

        {/* Results Panel */}
        <div className="lg:col-span-2">
          {!showResults && !running && (
            <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-12">
              <div className="text-center text-gray-500">
                <BarChart3 className="w-16 h-16 mx-auto mb-4 text-gray-300" />
                <h3 className="text-gray-700 mb-2">No Comparison Results</h3>
                <p>Upload your data and select a public dataset to compare</p>
              </div>
            </div>
          )}

          {running && (
            <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-12">
              <div className="text-center">
                <div className="w-16 h-16 border-4 border-blue-600 border-t-transparent rounded-full animate-spin mx-auto mb-4" />
                <h3 className="text-gray-700 mb-2">Analyzing Data...</h3>
                <p className="text-gray-500">Comparing against {publicDataset}</p>
              </div>
            </div>
          )}

          {showResults && (
            <div className="space-y-6">
              {/* Results Header */}
              <div className="bg-green-50 border border-green-200 rounded-lg p-4 flex items-center gap-3">
                <BarChart3 className="w-6 h-6 text-green-600" />
                <div>
                  <h3 className="text-green-900">Comparison Complete</h3>
                  <p className="text-sm text-green-700">
                    Your data vs. {publicDataset.replace('_', ' ').toUpperCase()}
                  </p>
                </div>
              </div>

              {/* Comparison Chart */}
              <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
                <h3 className="text-gray-900 mb-4">
                  {comparisonMetric === 'abundance' && 'Bacterial Abundance Comparison'}
                  {comparisonMetric === 'diversity' && 'Alpha Diversity Comparison'}
                  {comparisonMetric === 'beta' && 'Beta Diversity Analysis'}
                  {comparisonMetric === 'richness' && 'Species Richness Comparison'}
                </h3>
                <ResponsiveContainer width="100%" height={400}>
                  <BarChart data={mockComparisonData}>
                    <CartesianGrid strokeDasharray="3 3" />
                    <XAxis dataKey="bacteria" />
                    <YAxis label={{ value: 'Relative Abundance (%)', angle: -90, position: 'insideLeft' }} />
                    <Tooltip />
                    <Bar dataKey="yourData" fill="#2563eb" name="Your Data" />
                    <Bar dataKey="publicData" fill="#7c3aed" name="Public Dataset" />
                  </BarChart>
                </ResponsiveContainer>
              </div>

              {/* Statistical Summary */}
              <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
                <h3 className="text-gray-900 mb-4">Statistical Summary</h3>
                <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
                  <StatCard label="Similarity Score" value="87.3%" />
                  <StatCard label="Correlation" value="0.82" />
                  <StatCard label="P-value" value="0.0023" />
                  <StatCard label="Shannon Index (Yours)" value="3.42" />
                  <StatCard label="Shannon Index (Public)" value="3.28" />
                  <StatCard label="Samples Compared" value="492" />
                </div>
              </div>

              {/* Key Findings */}
              <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
                <h3 className="text-gray-900 mb-4">Key Findings</h3>
                <ul className="space-y-2 text-gray-700">
                  <li className="flex items-start gap-2">
                    <span className="text-blue-600">•</span>
                    <span>Your sample shows higher Lactobacillus abundance compared to the public dataset (65% vs 58%)</span>
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="text-blue-600">•</span>
                    <span>Gardnerella levels are lower in your sample (12% vs 18%)</span>
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="text-blue-600">•</span>
                    <span>Overall microbial composition is statistically similar (p &lt; 0.01)</span>
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="text-blue-600">•</span>
                    <span>Alpha diversity indices are comparable between datasets</span>
                  </li>
                </ul>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function StatCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="p-4 bg-gray-50 rounded-md border border-gray-200">
      <p className="text-sm text-gray-600 mb-1">{label}</p>
      <p className="text-gray-900">{value}</p>
    </div>
  );
}
