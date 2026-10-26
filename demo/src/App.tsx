import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { Header } from './components/Header';
import { Navigation } from './components/Navigation';
import { DashboardPage } from './pages/DashboardPage';
import { ShortReadPage } from './pages/ShortReadPage';
import { LongReadPage } from './pages/LongReadPage';
import { ComparePage } from './pages/ComparePage';
import { RunProgressPage } from './pages/RunProgressPage';

export type ReadType = 'short' | 'long';

export default function App() {
  return (
    <BrowserRouter>
      <div className="min-h-screen bg-gray-50">
        <Header />
        <Navigation />
        
        <div className="max-w-7xl mx-auto px-6 py-8">
          <Routes>
            <Route path="/" element={<DashboardPage />} />
            <Route path="/short-read" element={<ShortReadPage />} />
            <Route path="/long-read" element={<LongReadPage />} />
            <Route path="/compare" element={<ComparePage />} />
            <Route path="/run-progress" element={<RunProgressPage />} />
          </Routes>
        </div>
      </div>
    </BrowserRouter>
  );
}